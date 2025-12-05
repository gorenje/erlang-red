Fly.io Deployment
---

A sample Dockerfile `Dockerfile.fly` is provided to allow for easy launching of an instance as a fly application.
The provided shell script (`fly_er.sh`) sets some common expected parameters for the launch.
Advanced users may wish to examine the `fly launch` line therein and adjust for their requirements.

Heroku Deployment
---

Using the container stack at heroku, deployment becomes a `git push heroku` after the usual heroku setup:

- `heroku login` --> `heroku git:remote -a <app name>` --> `heroku stack:set container` --> `git push heroku`

However the [Dockerfile.heroku](Dockerfile.heroku) does not start the flow editor, the image is designed to run a set of flows, in this case (at time of writing) a simple website with a single page.

Basically this [flow](https://github.com/gorenje/erlang-red/blob/main/priv/testflows/flow.499288ab4007ac6a.json) is the [red-erik.org](https://red-erik.org) site.

The image does this by setting the following ENV variables:

- `COMPUTEFLOW`=`499288ab4007ac6a` - flow to be used. This can also be a comma separated list of flows that are all started.
- `DISABLE_FLOWEDITOR`=`YES` - any value will do, if set the flow editor is disabled.

Also be aware that Erlang-Red supports a `PORT` env variable to specifying the port upon which Cowboy will listen on for connections. The default is 8080.

Heroku uses this to specify the port to connect for a docker image so that its load balancer can get it right.
