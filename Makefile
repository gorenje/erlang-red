.DEFAULT_GOAL := compile

##
## Development docker image - used for local development.
## assumes codebase happens to be located at /mnt/github/erlang-red ...
build-docker-container:
	docker build -f dockerfiles/Dockerfile.dev -t erlang-shell .

start-docker-shell: build-docker-container
	docker network create erlang-red-node-red-bridge || true
	docker run -it \
		-v $(shell pwd):/code \
		-v $(shell pwd)/data:/data \
		--hostname erlang-red \
		--publish 9191:8080 \
		--publish 1883:1883 \
		--network erlang-red-node-red-bridge \
		--network mnmn \
		-w /code --rm erlang-shell bash

start-docker-shell-as-root: build-docker-container
	docker network create erlang-red-node-red-bridge || true
	docker run -it \
		-v $(shell pwd):/code \
		-v $(shell pwd)/data:/data \
		--hostname erlang-red \
		--publish 9191:8080 \
		--publish 1883:1883 \
		--network erlang-red-node-red-bridge \
		--network mnmn \
		--user root \
		-w /code --rm erlang-shell bash

start-docker-shell-raspberry: build-docker-container
	docker run -it -v $(shell pwd):/code \
		-v $(shell pwd)/data:/data \
		--device=/dev/i2c-1 \
		--hostname erlang-red-raspberry \
		--publish 9090:8080 \
		-w /code --rm erlang-shell bash

enter-docker-shell:
	docker exec -it $$(docker ps -f ancestor=erlang-shell -q) bash


##
## OTP 28.5.0
build-docker-container-28:
	docker build -f dockerfiles/Dockerfile.dev.28 -t erlang-shell-28 .

start-docker-shell-28: build-docker-container-28
	docker network create erlang-red-node-red-bridge || true
	docker run -it \
		-v $(shell pwd):/code \
		-v $(shell pwd)/data:/data \
		--hostname erlang-red \
		--publish 9191:8080 \
		--publish 1883:1883 \
		--network erlang-red-node-red-bridge \
		--network mnmn \
		-w /code --rm erlang-shell-28 bash


##
## Heroku deployment:
##
## >> The Docker build context is always set to the directory containing the Dockerfile and can’t be configured independently.
##   - https://devcenter.heroku.com/articles/build-docker-images-heroku-yml
##
## Heroku deployment no longer support.
##
## If their build context isn't configurable then I'm not supporting them.
##

##
## fly.io docker image
fly-io-build:
	docker build -f dockerfiles/Dockerfile.fly -t fly-er .
fly-io-run: fly-io-build
	docker run -it -p 6060:8080 -t fly-er
fly-io-enter:
	docker exec -it $$(docker ps -f ancestor=fly-er -q) sh

##
## hub.docker image
HUB_RELEASE := $(shell awk '/vsn/ && match($$0, /[0-9]+.[0-9]+.[0-9]+/) { printf substr($$0, RSTART, RLENGTH) }' src/erlang_red.app.src)
hub-docker-build:
	docker build -f dockerfiles/Dockerfile.hub -t gorenje/erlang-red:${HUB_RELEASE} .
hub-docker-run: hub-docker-build
	docker run -it -p 6060:8080 -t gorenje/erlang-red:${HUB_RELEASE}
hub-docker-push: hub-docker-build
	docker push gorenje/erlang-red:${HUB_RELEASE}
hub-docker-enter:
	docker exec -it $$(docker ps -f ancestor=gorenje/erlang-red:${HUB_RELEASE} -q) bash

##
## For local testing, start a kafka broker
kafka-start:
	IMAGE=apache/kafka:latest docker-compose -f dockerfiles/docker-compose-kafka.yml up

##
## Elixir compile example
elixir-build:
	docker build -f dockerfiles/Dockerfile.elixir -t er-elixir .
elixir-run: elixir-build
	docker run -it -t er-elixir sh

## http://1194online.com/
tcp-beacon:
	nc -lk -p 1194 -c "while date ; do sleep 1 ; done"
tcp-bidirectional-beacon:
	(while date ; do sleep 1 ; done) | nc -lk -p 1194

##
## The following are done inside the docker container - after running
## make enter-docker-shell
##
get-deps:
	rebar3 get-deps

compile:
	rebar3 compile

compile-loop:
	while [ 1 ] ; do make -s compile ; sleep 2 ; reset ; done

shell:
	rebar3 shell

app-start:
	rebar3 shell --config priv/sys.config --apps erlang_red

app-start-loop:
	while [ 1 ] ; do make -s app-start ; done

eunit-test:
	rebar3 eunit

clean:
	rm -fr _build

clean-really: clean
	rm -fr rebar.lock

# This helps understanding dialyzser
#  --> https://grantwinney.com/common-dialyzer-errors-and-solutions-in-erlang/
#  --> https://erlangforums.com/t/unknown-type-ranch-ref-0-dialyzer-warning-in-cowboy-req-on-erlang-otp-26/2760 - discussion "unknown functions"
dialyzer:
	rebar3 dialyzer

format-code:
	rebar3 fmt -w

release:
	rebar3 release
