export SHELL := /bin/bash

all: \
	scaleway

# cat_env = $(eval export $(shell sed -ne 's/ *#.*$$//; /./ s/=.*$$// p' .env.$1))

# scaleway: $(eval export
scaleway scaleway.%: export SHELL := $(shell grep '[^\s#].*' .env.scaleway | xargs) $(SHELL)
scaleway.init:
	terraform init -upgrade
scaleway.deinit:
	terraform deinit
scaleway.apply:
	terraform apply -auto-approve $(shell grep '[^\s#].*' .env.scaleway | sed 's,^,-var ,' | xargs)
scaleway.destroy:
	terraform destroy -auto-approve $(shell grep '[^\s#].*' .env.scaleway | sed 's,^,-var ,' | xargs)
scaleway.shell:
	$(SHELL)

scaleway.inspect: %.inspect:
	k9s --kubeconfig providers/$*/kubeconfig.yml

inspect: scaleway.inspect
