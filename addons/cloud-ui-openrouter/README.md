# Cloud UI OpenRouter

Patches the ToolHive Cloud UI deployment to add an OpenRouter API key, enabling model access through OpenRouter.

## What it does

- Creates an OpenRouter API key secret in `toolhive-system`
- Patches the existing cloud-ui Deployment to inject the key as an environment variable
- Cloud UI restarts automatically to pick up the change

## Prerequisites

- Demo sandbox cluster running (`bootstrap.sh` completed)
- An [OpenRouter](https://openrouter.ai/) API key

## Deploy

```bash
cp .env.example .env   # then fill in your OpenRouter key
./deploy.sh
```

## Teardown

```bash
./teardown.sh
```

Note: teardown removes the secret and attempts to remove the patched env var. A full reset of cloud-ui can be done by re-running the relevant section of `bootstrap.sh`.
