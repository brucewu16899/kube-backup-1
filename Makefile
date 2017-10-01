.PHONY: build test push

ORG ?= deitch
IMAGE ?= kube-backup
HASH ?= latest
FLAGNS ?= backuprestore-donotuse

build:
	docker build -t $(ORG)/$(IMAGE):$(HASH) .

push: build
	docker push $(ORG)/$(IMAGE):$(HASH)

test:
	kubectl delete ns backuprestore-donotuse
	kubectl apply -f ./test/
	kubectl apply -f ./kube-backup.yml
	@$(SHELL) -c 'secs=200; while [ $${secs} -gt 0 ]; do echo "\\r$${secs}\\c"; sleep 1; : $$((secs--)); done'
	kubectl -n kube-system scale deployment kube-backup --replicas=0
	kubectl delete -f ./test/services.yml
	kubectl -n kube-system scale deployment kube-backup --replicas=1
	kubectl delete ns backuprestore-donotuse
	@$(SHELL) -c 'secs=200; while [ $${secs} -gt 0 ]; do echo "\\r$${secs}\\c"; sleep 1; : $$((secs--)); done'
	kubectl get ns -l test=backup
	kubectl get all -l test=backup
	kubectl get configmap -l test=backup
