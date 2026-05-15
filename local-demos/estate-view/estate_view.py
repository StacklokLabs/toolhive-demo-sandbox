#!/usr/bin/env python3
"""Read-only ToolHive estate inventory prototype.

This script queries Kubernetes for ToolHive CRDs, builds a small domain graph,
and renders an estate view aimed at platform and security conversations. It is
intentionally scoped to ToolHive resources rather than being a general-purpose
Kubernetes dashboard.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import re
import shutil
import subprocess
import sys
from collections import defaultdict
from typing import Any
from urllib.parse import urlparse


TOOLHIVE_RESOURCES = {
    "MCPServer": "mcpservers.toolhive.stacklok.dev",
    "MCPRemoteProxy": "mcpremoteproxies.toolhive.stacklok.dev",
    "MCPServerEntry": "mcpserverentries.toolhive.stacklok.dev",
    "VirtualMCPServer": "virtualmcpservers.toolhive.stacklok.dev",
    "MCPGroup": "mcpgroups.toolhive.stacklok.dev",
    "MCPOIDCConfig": "mcpoidcconfigs.toolhive.stacklok.dev",
    "MCPExternalAuthConfig": "mcpexternalauthconfigs.toolhive.stacklok.dev",
    "MCPToolConfig": "mcptoolconfigs.toolhive.stacklok.dev",
    "MCPTelemetryConfig": "mcptelemetryconfigs.toolhive.stacklok.dev",
    "MCPRegistry": "mcpregistries.toolhive.stacklok.dev",
    "EmbeddingServer": "embeddingservers.toolhive.stacklok.dev",
    "VirtualMCPCompositeToolDefinition": (
        "virtualmcpcompositetooldefinitions.toolhive.stacklok.dev"
    ),
}

OPTIONAL_RESOURCES = {
    "HTTPRoute": "httproutes.gateway.networking.k8s.io",
}

ANNOTATION_PREFIX = "toolhive.stacklok.dev/"
REGISTRY_EXPORT = ANNOTATION_PREFIX + "registry-export"
REGISTRY_URL = ANNOTATION_PREFIX + "registry-url"
REGISTRY_TITLE = ANNOTATION_PREFIX + "registry-title"
AUTHZ_CLAIMS = ANNOTATION_PREFIX + "authz-claims"
TOOL_DEFINITIONS = ANNOTATION_PREFIX + "tool-definitions"

WORKLOAD_KINDS = ("MCPServer", "MCPRemoteProxy", "MCPServerEntry")
EXPOSED_KINDS = ("MCPServer", "MCPRemoteProxy", "MCPServerEntry", "VirtualMCPServer")


def kubectl_json(args: list[str], *, optional: bool = False) -> tuple[dict[str, Any], str | None]:
    cmd = ["kubectl", *args, "-o", "json"]
    proc = subprocess.run(cmd, text=True, capture_output=True)
    if proc.returncode != 0:
        if optional:
            return {"items": []}, proc.stderr.strip()
        raise RuntimeError(f"{' '.join(cmd)} failed:\n{proc.stderr.strip()}")
    try:
        return json.loads(proc.stdout), None
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"{' '.join(cmd)} returned invalid JSON: {exc}") from exc


def kubectl_text(args: list[str], *, optional: bool = False) -> tuple[str, str | None]:
    cmd = ["kubectl", *args]
    proc = subprocess.run(cmd, text=True, capture_output=True)
    if proc.returncode != 0:
        if optional:
            return "", proc.stderr.strip()
        raise RuntimeError(f"{' '.join(cmd)} failed:\n{proc.stderr.strip()}")
    return proc.stdout.strip(), None


def nested(obj: dict[str, Any], path: str, default: Any = None) -> Any:
    cur: Any = obj
    for part in path.split("."):
        if isinstance(cur, dict) and part in cur:
            cur = cur[part]
        else:
            return default
    return cur


def metadata(obj: dict[str, Any]) -> dict[str, Any]:
    return obj.get("metadata", {})


def name(obj: dict[str, Any]) -> str:
    return str(metadata(obj).get("name", ""))


def namespace(obj: dict[str, Any]) -> str:
    return str(metadata(obj).get("namespace", ""))


def namespaced_name(obj: dict[str, Any]) -> str:
    ns = namespace(obj)
    n = name(obj)
    return f"{ns}/{n}" if ns else n


def annotations(obj: dict[str, Any]) -> dict[str, str]:
    anns = metadata(obj).get("annotations") or {}
    return {str(k): str(v) for k, v in anns.items()}


def annotation(obj: dict[str, Any], key: str, default: str = "") -> str:
    return annotations(obj).get(key, default)


def is_registry_exported(obj: dict[str, Any]) -> bool:
    return annotation(obj, REGISTRY_EXPORT).lower() == "true"


def parse_json_annotation(obj: dict[str, Any], key: str) -> Any:
    raw = annotation(obj, key)
    if not raw:
        return None
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        return {"_parse_error": raw}


def parse_claims(obj: dict[str, Any]) -> dict[str, Any]:
    parsed = parse_json_annotation(obj, AUTHZ_CLAIMS)
    return parsed if isinstance(parsed, dict) else {}


def claim_groups(claims: dict[str, Any]) -> list[str]:
    groups = claims.get("groups")
    if groups is None:
        return []
    if isinstance(groups, str):
        return [part.strip().lstrip("/") for part in re.split(r"[, ]+", groups) if part.strip()]
    if isinstance(groups, list):
        return [str(part).strip().lstrip("/") for part in groups if str(part).strip()]
    return [str(groups).strip().lstrip("/")]


def claims_label(claims: dict[str, Any]) -> str:
    if not claims:
        return "no per-entry claims"
    groups = claim_groups(claims)
    if groups:
        return "groups: " + ", ".join(groups)
    parts = [f"{k}: {v}" for k, v in sorted(claims.items())]
    return "; ".join(parts)


def parse_tool_definitions(obj: dict[str, Any]) -> list[dict[str, Any]]:
    parsed = parse_json_annotation(obj, TOOL_DEFINITIONS)
    if isinstance(parsed, list):
        return [item for item in parsed if isinstance(item, dict)]
    return []


def public_title(obj: dict[str, Any]) -> str:
    return annotation(obj, REGISTRY_TITLE) or name(obj)


def phase(obj: dict[str, Any]) -> str:
    return str(nested(obj, "status.phase", "") or nested(obj, "status.status", "") or "")


def ready(obj: dict[str, Any]) -> str:
    value = nested(obj, "status.ready", "")
    if value != "":
        return str(value)
    conditions = nested(obj, "status.conditions", []) or []
    for cond in conditions:
        if cond.get("type") == "Ready":
            return str(cond.get("status", ""))
    return ""


def condition_status(obj: dict[str, Any], condition_type: str) -> str:
    for cond in nested(obj, "status.conditions", []) or []:
        if cond.get("type") == condition_type:
            return str(cond.get("status", ""))
    return ""


def status_label(obj: dict[str, Any]) -> str:
    ph = phase(obj)
    if ph:
        return ph
    rd = ready(obj)
    if rd:
        return f"Ready={rd}"
    valid = condition_status(obj, "Valid")
    if valid:
        return f"Valid={valid}"
    config_valid = condition_status(obj, "ConfigurationValid")
    if config_valid:
        return f"ConfigurationValid={config_valid}"
    return ""


def is_ready_like(obj: dict[str, Any]) -> bool:
    return (
        phase(obj) == "Ready"
        or ready(obj).lower() == "true"
        or condition_status(obj, "Valid").lower() == "true"
        or condition_status(obj, "ConfigurationValid").lower() == "true"
    )


def resource_url(obj: dict[str, Any]) -> str:
    return str(nested(obj, "status.url", "") or annotation(obj, REGISTRY_URL) or "")


def service_name_from_url(url: str) -> str:
    if not url:
        return ""
    host = urlparse(url).hostname or ""
    return host.split(".")[0] if host else ""


def group_ref(obj: dict[str, Any]) -> str:
    return str(nested(obj, "spec.groupRef.name", "") or "")


def object_ref(ns: str, ref_name: str) -> str:
    return f"{ns}/{ref_name}" if ref_name else ""


def reference_name(ref: Any) -> str:
    if isinstance(ref, dict):
        return str(ref.get("name", ""))
    return ""


def authz_config_for(kind: str, obj: dict[str, Any]) -> dict[str, Any] | None:
    if kind == "VirtualMCPServer":
        return nested(obj, "spec.incomingAuth.authzConfig")
    return nested(obj, "spec.authzConfig")


def inline_policies(authz_config: dict[str, Any] | None) -> list[str]:
    if not isinstance(authz_config, dict):
        return []
    inline = authz_config.get("inline") or {}
    policies = inline.get("policies") or []
    return [str(policy) for policy in policies]


def policy_summary(authz_config: dict[str, Any] | None) -> str:
    if not isinstance(authz_config, dict):
        return "none"
    cfg_type = str(authz_config.get("type", "unknown"))
    policies = inline_policies(authz_config)
    if not policies:
        cm = nested(authz_config, "configMap.name")
        return f"{cfg_type} configMap {cm}" if cm else cfg_type

    joined = "\n".join(policies)
    permits = len(re.findall(r"\bpermit\s*\(", joined))
    forbids = len(re.findall(r"\bforbid\s*\(", joined))
    groups = sorted(
        set(
            re.findall(r'THVGroup::"([^"]+)"', joined)
            + re.findall(r'groups\.contains\("([^"]+)"\)', joined)
            + re.findall(r'claim_groups\.contains\("([^"]+)"\)', joined)
        )
    )
    resource_patterns = sorted(set(re.findall(r'resource\.name\s+like\s+"([^"]+)"', joined)))
    bits = [f"{cfg_type}: {permits} permit"]
    if forbids:
        bits.append(f"{forbids} forbid")
    if groups:
        bits.append("groups " + ", ".join(groups))
    if resource_patterns:
        bits.append("resources " + ", ".join(resource_patterns))
    upstream = nested(authz_config, "inline.primaryUpstreamProvider")
    if upstream:
        bits.append(f"upstream {upstream}")
    return "; ".join(bits)


def auth_summary(kind: str, obj: dict[str, Any]) -> str:
    if kind == "VirtualMCPServer":
        incoming = nested(obj, "spec.incomingAuth", {}) or {}
        auth_type = str(incoming.get("type", ""))
        if auth_type == "anonymous":
            return "anonymous"
        oidc_name = reference_name(incoming.get("oidcConfigRef"))
        summary = auth_type or "unspecified"
        if oidc_name:
            summary += f" via {oidc_name}"
        if authz_config_for(kind, obj):
            summary += " + Cedar"
        return summary

    oidc_name = reference_name(nested(obj, "spec.oidcConfigRef", {}))
    auth_server = reference_name(nested(obj, "spec.authServerRef", {}))
    parts = []
    if oidc_name:
        parts.append(f"OIDC via {oidc_name}")
    if auth_server:
        parts.append(f"embedded AS {auth_server}")
    if authz_config_for(kind, obj):
        parts.append("Cedar")
    return " + ".join(parts) if parts else "none"


def has_toolhive_call_time_auth(kind: str, obj: dict[str, Any]) -> bool:
    if kind == "VirtualMCPServer":
        return str(nested(obj, "spec.incomingAuth.type", "") or "") != "anonymous"
    return bool(
        reference_name(nested(obj, "spec.oidcConfigRef", {}))
        or reference_name(nested(obj, "spec.authServerRef", {}))
    )


def external_auth_summary(kind: str, obj: dict[str, Any]) -> str:
    if kind == "VirtualMCPServer":
        source = str(nested(obj, "spec.outgoingAuth.source", "") or "")
        if source:
            return source
    ext = reference_name(nested(obj, "spec.externalAuthConfigRef", {}))
    return ext or "none"


def table(headers: list[str], rows: list[list[Any]]) -> str:
    if not rows:
        return "_None found._"
    normalized = [[str(cell) if cell is not None else "" for cell in row] for row in rows]
    widths = [
        max(len(headers[idx]), *(len(row[idx]) for row in normalized))
        for idx in range(len(headers))
    ]
    out = []
    out.append("| " + " | ".join(headers[idx].ljust(widths[idx]) for idx in range(len(headers))) + " |")
    out.append("| " + " | ".join("-" * widths[idx] for idx in range(len(headers))) + " |")
    for row in normalized:
        out.append("| " + " | ".join(row[idx].ljust(widths[idx]) for idx in range(len(headers))) + " |")
    return "\n".join(out)


def bullet_list(items: list[str]) -> str:
    if not items:
        return "_None._"
    return "\n".join(f"- {item}" for item in items)


def collect_resources(namespace_filter: str | None) -> tuple[dict[str, list[dict[str, Any]]], list[str]]:
    warnings: list[str] = []
    resources: dict[str, list[dict[str, Any]]] = {}
    for kind, resource in TOOLHIVE_RESOURCES.items():
        args = ["get", resource]
        if namespace_filter:
            args.extend(["-n", namespace_filter])
        else:
            args.append("-A")
        data, warning = kubectl_json(args, optional=True)
        if warning:
            warnings.append(f"Could not read {resource}: {warning}")
        resources[kind] = data.get("items", [])

    for kind, resource in OPTIONAL_RESOURCES.items():
        args = ["get", resource]
        if namespace_filter:
            args.extend(["-n", namespace_filter])
        else:
            args.append("-A")
        data, warning = kubectl_json(args, optional=True)
        if warning:
            warnings.append(f"Could not read optional {resource}: {warning}")
        resources[kind] = data.get("items", [])

    return resources, warnings


def load_current_context() -> str:
    context, _ = kubectl_text(["config", "current-context"], optional=True)
    return context


def load_demo_personas() -> list[dict[str, Any]]:
    data, _ = kubectl_json(
        ["get", "configmap", "keycloak-realm-import", "-n", "keycloak"],
        optional=True,
    )
    cm_data = data.get("data") or {}
    realm_raw = ""
    for value in cm_data.values():
        if isinstance(value, str) and '"realm"' in value and '"users"' in value:
            realm_raw = value
            break
    if not realm_raw:
        return []
    try:
        realm = json.loads(realm_raw)
    except json.JSONDecodeError:
        return []

    personas = []
    for user in realm.get("users", []):
        username = str(user.get("username", ""))
        groups = [
            str(group).strip().lstrip("/")
            for group in user.get("groups", [])
            if str(group).strip()
        ]
        personas.append(
            {
                "username": username,
                "email": user.get("email", ""),
                "groups": sorted(groups),
            }
        )
    return sorted(personas, key=lambda item: item["username"])


def parse_registry_config(resources: dict[str, list[dict[str, Any]]]) -> dict[str, Any]:
    registries = resources.get("MCPRegistry", [])
    if not registries:
        return {}
    # Keep this intentionally light. The report is useful even without parsing YAML.
    config_yaml = str(nested(registries[0], "spec.configYAML", "") or "")
    source_claims: dict[str, str] = {}
    public_paths: list[str] = []
    super_admins: list[str] = []

    current_source = ""
    in_sources = False
    in_public_paths = False
    for raw_line in config_yaml.splitlines():
        line = raw_line.rstrip()
        stripped = line.strip()
        if stripped == "sources:":
            in_sources = True
            current_source = ""
            continue
        if stripped == "registries:":
            in_sources = False
            current_source = ""
        if stripped == "publicPaths:":
            in_public_paths = True
            continue
        if in_public_paths:
            if stripped.startswith("- "):
                public_paths.append(stripped[2:].strip())
                continue
            if stripped and not stripped.startswith("#"):
                in_public_paths = False
        if in_sources:
            match = re.match(r"\s*-\s+name:\s+(.+)", line)
            if match:
                current_source = match.group(1).strip().strip('"')
                continue
            match = re.match(r"\s+groups:\s+(.+)", line)
            if current_source and match:
                source_claims[current_source] = match.group(1).strip().strip('"')
        if "preferred_username:" in stripped:
            super_admins.append(stripped.split(":", 1)[1].strip().strip('"'))

    public_registry_has_k8s = bool(re.search(r"-\s+name:\s+public\b[\s\S]*?-\s+k8s\b", config_yaml))
    return {
        "name": name(registries[0]),
        "configYAML": config_yaml,
        "sourceClaims": source_claims,
        "publicPaths": public_paths,
        "superAdmins": sorted(set(super_admins)),
        "publicRegistryHasK8s": public_registry_has_k8s,
    }


def route_index(routes: list[dict[str, Any]]) -> dict[str, list[dict[str, str]]]:
    by_backend: dict[str, list[dict[str, str]]] = defaultdict(list)
    for route in routes:
        hostnames = nested(route, "spec.hostnames", []) or []
        hostname_label = ",".join(str(host) for host in hostnames)
        for rule in nested(route, "spec.rules", []) or []:
            paths = []
            for match in rule.get("matches") or []:
                path_value = nested(match, "path.value", "")
                if path_value:
                    paths.append(str(path_value))
            for backend in rule.get("backendRefs") or []:
                backend_name = str(backend.get("name", ""))
                if not backend_name:
                    continue
                by_backend[backend_name].append(
                    {
                        "route": namespaced_name(route),
                        "hostnames": hostname_label,
                        "paths": ",".join(paths),
                    }
                )
    return by_backend


def build_group_graph(resources: dict[str, list[dict[str, Any]]]) -> dict[str, Any]:
    groups_by_key = {namespaced_name(obj): obj for obj in resources.get("MCPGroup", [])}
    members: dict[str, dict[str, list[str]]] = defaultdict(lambda: defaultdict(list))
    frontends: dict[str, list[str]] = defaultdict(list)

    for kind in WORKLOAD_KINDS:
        for obj in resources.get(kind, []):
            group = group_ref(obj)
            if group:
                members[object_ref(namespace(obj), group)][kind].append(name(obj))

    for obj in resources.get("VirtualMCPServer", []):
        group = group_ref(obj)
        if group:
            frontends[object_ref(namespace(obj), group)].append(name(obj))

    return {"groups": groups_by_key, "members": members, "frontends": frontends}


def persona_can_see(persona: dict[str, Any], obj: dict[str, Any]) -> str:
    if not is_registry_exported(obj):
        return ""
    groups = claim_groups(parse_claims(obj))
    if not groups:
        return "?"
    persona_groups = set(persona.get("groups", []))
    return "yes" if persona_groups.intersection(groups) else "no"


def build_findings(resources: dict[str, list[dict[str, Any]]], registry_config: dict[str, Any]) -> list[str]:
    findings: list[str] = []
    group_graph = build_group_graph(resources)
    groups = group_graph["groups"]

    for kind in EXPOSED_KINDS:
        for obj in resources.get(kind, []):
            label = f"{kind} {namespaced_name(obj)}"
            exported = is_registry_exported(obj)
            auth = auth_summary(kind, obj)
            tools = parse_tool_definitions(obj)
            tool_names = [str(tool.get("name", "")) for tool in tools]
            destructive_tools = [
                tool
                for tool in tool_names
                if re.search(r"(^|_)(apply|delete|create|update|merge|post|write)_?", tool)
            ]

            if exported and not annotation(obj, REGISTRY_URL):
                findings.append(f"[P2] {label} is registry-exported but has no registry-url annotation.")
            if exported and not annotation(obj, REGISTRY_TITLE):
                findings.append(f"[P3] {label} is registry-exported but has no registry-title annotation.")
            if exported and not parse_claims(obj):
                findings.append(
                    f"[P3] {label} is registry-exported with no per-entry authz-claims annotation."
                )
            if exported and not tools:
                findings.append(
                    f"[P3] {label} is registry-exported but has no parsed tool-definitions annotation."
                )
            if exported and not has_toolhive_call_time_auth(kind, obj):
                findings.append(
                    f"[P2] {label} has registry visibility controls but no ToolHive call-time auth."
                )
            if exported and not has_toolhive_call_time_auth(kind, obj) and destructive_tools:
                findings.append(
                    f"[P1] {label} exposes potentially state-changing tools without call-time auth: "
                    + ", ".join(destructive_tools[:8])
                    + (" ..." if len(destructive_tools) > 8 else "")
                )

            group = group_ref(obj)
            if group and object_ref(namespace(obj), group) not in groups:
                findings.append(f"[P2] {label} references missing MCPGroup {namespace(obj)}/{group}.")

    for obj in resources.get("VirtualMCPServer", []):
        backend_names = set(str(item.get("name", "")) for item in nested(obj, "status.discoveredBackends", []) or [])
        group_key = object_ref(namespace(obj), group_ref(obj))
        expected = set()
        for kind_members in build_group_graph(resources)["members"].get(group_key, {}).values():
            expected.update(kind_members)
        missing = sorted(expected - backend_names)
        if expected and missing:
            findings.append(
                f"[P2] VirtualMCPServer {namespaced_name(obj)} has group members not discovered as backends: "
                + ", ".join(missing)
            )

    for obj in resources.get("MCPOIDCConfig", []):
        if nested(obj, "spec.inline.insecureAllowHTTP", False):
            findings.append(
                f"[P3] MCPOIDCConfig {namespaced_name(obj)} allows insecure HTTP. Fine for demos, risky for production."
            )
        if nested(obj, "spec.inline.jwksAllowPrivateIP", False):
            findings.append(
                f"[P3] MCPOIDCConfig {namespaced_name(obj)} allows JWKS private IPs. Fine for demos, risky for production."
            )

    if registry_config.get("publicRegistryHasK8s"):
        findings.append(
            "[P2] MCPRegistry public registry includes the k8s source, so registry-exported in-cluster entries can be listed without auth."
        )

    return findings


def estate_snapshot(namespace_filter: str | None = None) -> dict[str, Any]:
    resources, warnings = collect_resources(namespace_filter)
    registry_config = parse_registry_config(resources)
    return {
        "generatedAt": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
        "context": load_current_context(),
        "namespace": namespace_filter or "all",
        "resources": resources,
        "warnings": warnings,
        "personas": load_demo_personas(),
        "registryConfig": registry_config,
        "groupGraph": build_group_graph(resources),
        "routesByBackend": route_index(resources.get("HTTPRoute", [])),
        "findings": build_findings(resources, registry_config),
    }


def render_markdown(snapshot: dict[str, Any], include_raw_policies: bool) -> str:
    resources = snapshot["resources"]
    routes_by_backend = snapshot["routesByBackend"]
    registry_config = snapshot["registryConfig"]
    group_graph = snapshot["groupGraph"]
    personas = snapshot["personas"]

    out: list[str] = []
    out.append("# ToolHive Estate View")
    out.append("")
    out.append(f"- Generated: {snapshot['generatedAt']}")
    out.append(f"- Kubernetes context: `{snapshot.get('context') or 'unknown'}`")
    out.append(f"- Namespace scope: `{snapshot['namespace']}`")
    if registry_config.get("name"):
        out.append(f"- Registry: `{registry_config['name']}`")
    if registry_config.get("publicPaths"):
        out.append("- Public registry paths: " + ", ".join(f"`{p}`" for p in registry_config["publicPaths"]))
    if registry_config.get("superAdmins"):
        out.append("- Registry super admins: " + ", ".join(f"`{u}`" for u in registry_config["superAdmins"]))

    out.append("")
    out.append("## Estate Summary")
    summary_rows = []
    for kind in TOOLHIVE_RESOURCES:
        count = len(resources.get(kind, []))
        if count:
            ready_count = sum(1 for obj in resources[kind] if is_ready_like(obj))
            summary_rows.append([kind, count, ready_count])
    out.append(table(["Kind", "Count", "Ready-ish"], summary_rows))

    out.append("")
    out.append("## Group Topology")
    group_rows = []
    for group_key, group in sorted(group_graph["groups"].items()):
        members = group_graph["members"].get(group_key, {})
        member_bits = []
        for kind in WORKLOAD_KINDS:
            values = sorted(members.get(kind, []))
            if values:
                member_bits.append(f"{kind}: " + ", ".join(values))
        frontends = ", ".join(sorted(group_graph["frontends"].get(group_key, []))) or "-"
        group_rows.append(
            [
                group_key,
                nested(group, "spec.description", ""),
                frontends,
                "; ".join(member_bits) or "-",
                status_label(group),
            ]
        )
    out.append(table(["MCPGroup", "Description", "vMCP front ends", "Backends", "Status"], group_rows))

    out.append("")
    out.append("## Gateways")
    gateway_rows = []
    for obj in sorted(resources.get("VirtualMCPServer", []), key=namespaced_name):
        status_url = resource_url(obj)
        service = service_name_from_url(status_url)
        routes = routes_by_backend.get(service, [])
        route_label = "; ".join(
            f"{route['route']} {route['hostnames']} {route['paths']}".strip()
            for route in routes
        )
        tool_count = len(parse_tool_definitions(obj))
        composite_refs = nested(obj, "spec.config.compositeToolRefs", []) or []
        composite_label = ", ".join(reference_name(ref) for ref in composite_refs) or "-"
        gateway_rows.append(
            [
                namespaced_name(obj),
                public_title(obj),
                group_ref(obj),
                nested(obj, "status.backendCount", ""),
                auth_summary("VirtualMCPServer", obj),
                claims_label(parse_claims(obj)) if is_registry_exported(obj) else "not exported",
                tool_count,
                composite_label,
                status_label(obj),
                route_label or "-",
            ]
        )
    out.append(
        table(
            [
                "Gateway",
                "Title",
                "Group",
                "Backends",
                "Call-time auth",
                "Registry claims",
                "Tools",
                "Composite tools",
                "Status",
                "Routes",
            ],
            gateway_rows,
        )
    )

    out.append("")
    out.append("## Workloads")
    workload_rows = []
    for kind in WORKLOAD_KINDS:
        for obj in sorted(resources.get(kind, []), key=namespaced_name):
            status_url = resource_url(obj)
            service = service_name_from_url(status_url)
            routes = routes_by_backend.get(service, [])
            route_label = "; ".join(f"{route['route']} {route['paths']}".strip() for route in routes)
            endpoint = annotation(obj, REGISTRY_URL) or status_url
            target = nested(obj, "spec.remoteUrl", "") or nested(obj, "spec.image", "") or endpoint
            workload_rows.append(
                [
                    kind,
                    namespaced_name(obj),
                    group_ref(obj) or "-",
                    target,
                    auth_summary(kind, obj),
                    external_auth_summary(kind, obj),
                    claims_label(parse_claims(obj)) if is_registry_exported(obj) else "not exported",
                    status_label(obj),
                    route_label or "-",
                ]
            )
    out.append(
        table(
            [
                "Kind",
                "Name",
                "Group",
                "Image/Remote",
                "Call-time auth",
                "Outgoing auth",
                "Registry claims",
                "Status",
                "Routes",
            ],
            workload_rows,
        )
    )

    out.append("")
    out.append("## Access Matrix")
    if personas:
        access_rows = []
        exported: list[tuple[str, dict[str, Any]]] = []
        for kind in EXPOSED_KINDS:
            for obj in resources.get(kind, []):
                if is_registry_exported(obj):
                    exported.append((kind, obj))
        for kind, obj in sorted(exported, key=lambda pair: (pair[0], namespaced_name(pair[1]))):
            row = [
                kind,
                namespaced_name(obj),
                public_title(obj),
                claims_label(parse_claims(obj)),
            ]
            for persona in personas:
                row.append(persona_can_see(persona, obj))
            row.append(auth_summary(kind, obj))
            row.append(policy_summary(authz_config_for(kind, obj)))
            access_rows.append(row)
        headers = ["Kind", "Name", "Title", "Registry claims"]
        headers.extend(persona["username"] for persona in personas)
        headers.extend(["Call-time auth", "Policy summary"])
        out.append(table(headers, access_rows))
        out.append("")
        out.append("Legend: `yes` means the demo user's groups match the resource's per-entry registry claims. `?` means the resource is exported but has no per-entry claims, so source/default registry behavior decides visibility.")
    else:
        out.append("_No demo Keycloak personas found. Showing claims only._")

    out.append("")
    out.append("## Auth And Identity")
    oidc_rows = []
    for obj in sorted(resources.get("MCPOIDCConfig", []), key=namespaced_name):
        refs = nested(obj, "status.referencingWorkloads", []) or []
        oidc_rows.append(
            [
                namespaced_name(obj),
                nested(obj, "spec.type", ""),
                nested(obj, "spec.inline.issuer", ""),
                ", ".join(f"{ref.get('kind')}/{ref.get('name')}" for ref in refs),
                status_label(obj),
            ]
        )
    out.append(table(["OIDC config", "Type", "Issuer", "Referenced by", "Status"], oidc_rows))

    out.append("")
    external_rows = []
    for obj in sorted(resources.get("MCPExternalAuthConfig", []), key=namespaced_name):
        refs = nested(obj, "status.referencingWorkloads", []) or []
        providers = nested(obj, "spec.embeddedAuthServer.upstreamProviders", []) or []
        provider_names = ", ".join(str(provider.get("name", "")) for provider in providers if provider.get("name"))
        external_rows.append(
            [
                namespaced_name(obj),
                nested(obj, "spec.type", ""),
                nested(obj, "spec.embeddedAuthServer.issuer", ""),
                provider_names or "-",
                ", ".join(f"{ref.get('kind')}/{ref.get('name')}" for ref in refs),
            ]
        )
    out.append(table(["External auth", "Type", "Issuer", "Upstreams", "Referenced by"], external_rows))

    out.append("")
    out.append("## Tool Surface")
    tool_rows = []
    for kind in ("VirtualMCPServer", *WORKLOAD_KINDS):
        for obj in sorted(resources.get(kind, []), key=namespaced_name):
            tools = parse_tool_definitions(obj)
            if not is_registry_exported(obj) and not tools:
                continue
            names = [str(tool.get("name", "")) for tool in tools if tool.get("name")]
            sample = ", ".join(names[:8])
            if len(names) > 8:
                sample += " ..."
            aggregation = nested(obj, "spec.config.aggregation.tools", []) or []
            filters = []
            for entry in aggregation:
                workload = str(entry.get("workload", ""))
                if entry.get("excludeAll"):
                    filters.append(f"{workload}: excludeAll")
                elif entry.get("filter"):
                    filters.append(f"{workload}: {len(entry.get('filter') or [])} filtered")
                elif entry.get("overrides"):
                    filters.append(f"{workload}: overrides")
            tool_rows.append(
                [
                    kind,
                    namespaced_name(obj),
                    len(names),
                    sample or "-",
                    "; ".join(filters) or "-",
                ]
            )
    out.append(table(["Kind", "Name", "Advertised tool count", "Sample tools", "Aggregation config"], tool_rows))

    out.append("")
    out.append("## Findings")
    out.append(bullet_list(snapshot["findings"]))

    if snapshot["warnings"]:
        out.append("")
        out.append("## Collection Warnings")
        out.append(bullet_list(snapshot["warnings"]))

    if include_raw_policies:
        raw_rows = []
        for kind in ("VirtualMCPServer", *WORKLOAD_KINDS):
            for obj in sorted(resources.get(kind, []), key=namespaced_name):
                policies = inline_policies(authz_config_for(kind, obj))
                for idx, policy in enumerate(policies, start=1):
                    raw_rows.append([kind, namespaced_name(obj), idx, "\n" + policy.strip()])
        out.append("")
        out.append("## Raw Inline Policies")
        out.append(table(["Kind", "Name", "#", "Policy"], raw_rows))

    return "\n".join(out) + "\n"


def redact_snapshot(snapshot: dict[str, Any]) -> dict[str, Any]:
    # Keep JSON output useful without dumping full Kubernetes objects or secret refs.
    compact: dict[str, Any] = {
        "generatedAt": snapshot["generatedAt"],
        "context": snapshot["context"],
        "namespace": snapshot["namespace"],
        "personas": snapshot["personas"],
        "warnings": snapshot["warnings"],
        "registryConfig": {
            key: value
            for key, value in snapshot["registryConfig"].items()
            if key != "configYAML"
        },
        "findings": snapshot["findings"],
        "resources": {},
    }
    for kind, items in snapshot["resources"].items():
        compact["resources"][kind] = [
            {
                "name": namespaced_name(obj),
                "phase": phase(obj),
                "ready": ready(obj),
                "status": status_label(obj),
                "group": group_ref(obj),
                "registryExported": is_registry_exported(obj),
                "registryTitle": public_title(obj),
                "registryUrl": annotation(obj, REGISTRY_URL),
                "registryClaims": parse_claims(obj),
                "auth": auth_summary(kind, obj),
                "policySummary": policy_summary(authz_config_for(kind, obj)),
                "toolCount": len(parse_tool_definitions(obj)),
            }
            for obj in items
        ]
    return compact


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate a read-only ToolHive estate report.")
    parser.add_argument("-n", "--namespace", help="Limit ToolHive CRD reads to one namespace.")
    parser.add_argument(
        "-o",
        "--output",
        choices=("markdown", "json"),
        default="markdown",
        help="Output format. Default: markdown.",
    )
    parser.add_argument(
        "--include-raw-policies",
        action="store_true",
        help="Include raw inline Cedar policies in markdown output.",
    )
    args = parser.parse_args()

    if not shutil.which("kubectl"):
        print("kubectl is required and was not found in PATH.", file=sys.stderr)
        return 2

    try:
        snapshot = estate_snapshot(args.namespace)
    except RuntimeError as exc:
        print(str(exc), file=sys.stderr)
        return 1

    if args.output == "json":
        print(json.dumps(redact_snapshot(snapshot), indent=2, sort_keys=True))
    else:
        print(render_markdown(snapshot, args.include_raw_policies), end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
