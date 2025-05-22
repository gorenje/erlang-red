##
## Development docker image - used for local development.
## assumes codebase happens to be located at /mnt/github/erlang-red ...
build-docker-container:
	docker build -f Dockerfile.dev -t erlang-shell .

start-docker-shell: build-docker-container
	docker run -it -v /mnt/github/erlang-red:/code -p 9090:8080 -w /code --rm erlang-shell bash

enter-docker-shell:
	docker exec -it $$(docker ps -f ancestor=erlang-shell -q) bash

##
## Heroku docker image
heroku-build:
	docker build -f Dockerfile.heroku -t heroku-red-erik .
heroku-run: heroku-build
	docker run -it -p 7070:8080 -t heroku-red-erik
heroku-enter:
	docker exec -it $$(docker ps -f ancestor=heroku-red-erik -q) bash
heroku-stop:
	docker kill $$(docker ps -f ancestor=heroku-red-erik -q)
heroku-console: heroku-build
	docker run -i -t heroku-red-erik /erlang-red/bin/erlang_red console
##
## fly.io docker image
fly-io-build:
	docker build -f Dockerfile.fly -t fly-er .
fly-io-run: fly-io-build
	docker run -it -p 6060:8080 -t fly-er
fly-io-enter:
	docker exec -it $$(docker ps -f ancestor=fly-er -q) sh

##
## Elixir compile example
elixir-build:
	docker build -f Dockerfile.elixir -t er-elixir .
elixir-run: elixir-build
	docker run -it -t er-elixir sh

check-testflows:
	diff -qr priv/testflows ../erlang-red-flow-testsuite  | grep -v preview.svg | grep -v nodedetails.json | grep -v README | grep -v .git | grep -v .image | grep -v 499288ab4007ac6a | grep -v b8e2ad1371ddb546 | grep -v c562c43e69bcf0af | grep -v f346d45c81f595e5 | grep -v  777bee1d06741240 | grep -v 9d3f5506aa810b22 || true

##
## The following are done inside the docker container - after running
## make enter-docker-shell
##
compile:
	rebar3 compile

compile-loop:
	while [ 1 ] ; do make -s compile ; sleep 2 ; reset ; done

shell:
	rebar3 shell

app-start:
	rebar3 shell --apps erlang_red

app-start-loop:
	while [ 1 ] ; do make -s app-start ; done

eunit-test:
	rebar3 eunit

# This helps understanding dialyzser
#  --> https://grantwinney.com/common-dialyzer-errors-and-solutions-in-erlang/
#  --> https://erlangforums.com/t/unknown-type-ranch-ref-0-dialyzer-warning-in-cowboy-req-on-erlang-otp-26/2760 - discussion "unknown functions"
dialyzer:
	rebar3 dialyzer

format-code:
	rebar3 fmt -w

release:
	rebar3 release
