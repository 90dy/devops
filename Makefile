export SHELL := /bin/bash

all: \
	scaleway

# cat_env = $(eval export $(shell sed -ne 's/ *#.*$$//; /./ s/=.*$$// p' .env.$1))

# scaleway: $(eval export
scaleway: export SHELL := $(shell grep '[^\s#].*' .env.scaleway | xargs) $(SHELL)
scaleway: vars := $(shell grep '[^\s#].*' .env.scaleway | sed 's,=.*,,' | xargs)
scaleway:
	# terraform init
	terraform apply $(shell grep '[^\s#].*' .env.scaleway | sed 's,^,-var ,' | xargs)

inspect.scaleway: inspect.%:
	k9s --kubeconfig $*.k8s.yml

inspect: inspect.scaleway
