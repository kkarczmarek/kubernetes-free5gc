IMG ?= ghcr.io/kkarczmarek/admission-webhook:0.1.0
RELEASE ?= free5gc
NAMESPACE ?= 5g-core
VALUES ?= helm-values/free5gc/values-minimal.yaml

.PHONY: build docker-build docker-push deploy-webhooks uninstall-webhooks tests install-free5gc

build:
	cd admission-controller && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o bin/server ./cmd/server

docker-build:
	docker build -t $(IMG) ./admission-controller

docker-push:
	docker push $(IMG)

deploy-webhooks:
	kubectl apply -f k8s/00-namespaces.yaml
	kubectl apply -f k8s/20-certmanager-issuer.yaml
	# Set image in Deployment
	sed 's|IMAGE_PLACEHOLDER|$(IMG)|g' k8s/30-webhook-deploy-svc.yaml | kubectl apply -f -
	kubectl apply -f k8s/40-mutatingwebhook.yaml
	kubectl apply -f k8s/50-validatingwebhook.yaml

uninstall-webhooks:
	kubectl delete -f k8s/50-validatingwebhook.yaml --ignore-not-found
	kubectl delete -f k8s/40-mutatingwebhook.yaml --ignore-not-found
	kubectl delete -f k8s/30-webhook-deploy-svc.yaml --ignore-not-found
	kubectl delete -f k8s/20-certmanager-issuer.yaml --ignore-not-found

install-free5gc:
	helm repo add free5gc https://charts.free5gc.org || true
	helm repo update
	helm upgrade --install $(RELEASE) free5gc/free5gc -n $(NAMESPACE) --create-namespace -f $(VALUES) --wait --timeout 15m

tests:
	kubectl apply -f tests/01-deploy-missing-labels.yaml || true
	kubectl apply -f tests/02-deploy-wrong-ns.yaml || true
	kubectl apply -f tests/03-deploy-bad-image.yaml || true
	kubectl apply -f tests/04-deploy-no-resources.yaml || true
