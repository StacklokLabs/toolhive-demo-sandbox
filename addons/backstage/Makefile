# Convenience targets for building and loading the Backstage image into the
# toolhive-demo-sandbox kind cluster. Use deploy.sh / teardown.sh for the
# full addon lifecycle.

CLUSTER_NAME := toolhive-demo-sandbox
IMAGE        := backstage-toolhive-demo:latest

.PHONY: build image load reload

# Build the JS bundle and backend — run this whenever plugin/template source changes.
build:
	yarn install
	yarn build:backend

# Build the Docker image.
image:
	docker build -t $(IMAGE) .

# Load the image into the kind cluster.
load:
	kind load docker-image $(IMAGE) --name $(CLUSTER_NAME)

# Rebuild everything and roll the deployment — shortcut for iterating on code.
reload: build image load
	kubectl rollout restart deployment/backstage -n backstage
	kubectl rollout status deployment/backstage -n backstage --timeout=3m
