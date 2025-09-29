Node-RED Serverless Frontend
====

These are all the static files for the Node-RED editor. These files were retrieved from a v4.0.9 installation of Node-RED. This is much the same how the [serverless Node-RED](https://cdn.flowhub.org) was created ([gitrepo](https://github.com/gorenje/cdn.flowhub.org)).

I update this when new stuff is discovered, i.e., images for very specific actions. I will endeavour to update the [retrieve.sh](retrieve.sh) will all necessary endpoints.

Build
---

To do the same, use the [retrieve.sh](retrieve.sh) script to scrape all the necessary files from a running Node-RED instance.

The [Makefile](Makefile) can also do this: `make retrieve`

Committing Changes
---

Also there will be changes that need reverting, the files here have been modified for Erlang-Red and these modifications aren't in the source Node-RED from which this code is retrieved. To do this, use `git restore -p ...` with staged changes. The '-p' option means interactively decided which changes are staged.
