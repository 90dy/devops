export SHELL := /bin/bash

all: \
	scaleway

# cat_env = $(eval export $(shell sed -ne 's/ *#.*$$//; /./ s/=.*$$// p' .env.$1))

# scaleway: $(eval export
scaleway scaleway.%: export SHELL := $(shell grep '[^\s#].*' .env.scaleway | xargs) $(SHELL)
scaleway.init:
	terraform init
scaleway.deinit:
	terraform deinit
scaleway.apply:
	terraform apply -auto-approve $(shell grep '[^\s#].*' .env.scaleway | sed 's,^,-var ,' | xargs)
scaleway.destroy:
	terraform destroy -auto-approve $(shell grep '[^\s#].*' .env.scaleway | sed 's,^,-var ,' | xargs)

inspect.scaleway: inspect.%:
	k9s --kubeconfig $*.k8s.yml

inspect: inspect.scaleway
