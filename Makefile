export SHELL := /bin/bash

.ONESHELL:


all: \
	scaleway

# cat_env = $(eval export $(shell sed -ne 's/ *#.*$$//; /./ s/=.*$$// p' .env.$1))

# scaleway: $(eval export
scw scaleway:
	export $$(grep -v '[^\]#.*' .env.$@ | xargs)
	terraform init
	# terraform apply

inspect:
	k9s --kubeconfig scaleway.k8s.yml
