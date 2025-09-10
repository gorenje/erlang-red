Erlang-Red - BEAM/Erlang backend for Node-RED
=====

[![Erlang CI](https://github.com/gorenje/erlang-red/actions/workflows/erlang.yml/badge.svg)](https://github.com/gorenje/erlang-red/actions/workflows/erlang.yml)
[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/gorenje/erlang-red)

Experimental Erlang backend to replace Node-REDs existing NodeJS backend, aiming for 100% compatible with existing flow code.

The goal is bring the advantages of low-code visual [flow-based programming](https://jpaulm.github.io/fbp/index.html) to a programming language that is designed for message passing and concurrency from the ground up, hence Erlang. More details described in the corresponding [blog post](https://blog.openmindmap.org/erlang-red).

Why?
---

[Node-RED](https://nodered.org) is great for creating data flows that actually describe concurrent processing, it is just a shame the NodeJS is single threaded. So why not use something that is multi-process from the ground up? Concurrency is guaranteed and included.

Also Erlang isn't the most understandable of programming language - unless one has fallen into in a [cauldron](https://en.wikipedia.org/wiki/Obelix) of Prolog, spiced with Lisp.

So won't it be great to have the simplicity of low-code visual flow based programming and the performance (and concurrency) of Erlang?

Trying Erlang-Red
---

Thanks to [@mwmiller](https://github.com/mwmiller), Erlang-Red can be tested at [ered.fly.dev](https://ered.fly.dev/node-red) or locally using docker:

    docker run --tty --publish 8080:8080 gorenje/erlang-red:0.2.5

Starts Erlang-Red listening on [localhost:8080/erlang-red](http://localhost:8080/erlang-red) and drops into an Eshell console for BEAM introspection.

[Erlang-Red at Docker Hub](https://hub.docker.com/r/gorenje/erlang-red).

Online Example
---

Sample [MQTT Broker](https://ered.fly.dev/erlang-red?tstid=dc897f402c53697f) with [explanation](https://flows.red-erik.org/f/dc897f402c53697f).

Embedding
---

Many thanks to [@joaohf](https://erlangforums.com/u/joaohf/summary) there is a Erlang-Red [recipe](https://meta-erlang.github.io/blog/2025/07/27/index/) for [Yocto project](https://www.yoctoproject.org).

Also I did a quick experiment with a [Raspberry Pi 4](Embedding.md) to get the [I2C](https://flows.red-erik.org/f/ea246f68766c8632) nodes working. That wasn't "true" embedding since Erlang-Red was running in a docker container on a Raspberry running a debian distribution!


Breadboard Programming
---

[Breadboards](https://en.wikipedia.org/wiki/Breadboard) are prototyping devices found in electronics. Erlang-Red can be best thought of as a programming [breadboard](https://blog.openmindmap.org/blog/breadboard-programming).

What are some tools for *software* prototyping? Besides AI and VScode. Software developers *create* prototypes but they don't *prototype* software.

A [telnet session](https://flows.red-erik.org/f/bff27e059752cb60) flow describes how breadboard programming can be done using Erlang-Red. That flow *prototypes* a possible *software* solution starting with a simple concurrent approach until a first final approach is found. All solutions are testable and usable - instantly and all solutions build on previous solutions - simply copy and paste the flows. That's prototyping.

Implementation of the [MQTT specs](https://docs.oasis-open.org/mqtt/mqtt/v3.1.1/os/mqtt-v3.1.1-os.html) to create an [MQTT broker](https://flows.red-erik.org/f/dc897f402c53697f) in Erlang-Red. The broker is created as a flow and at the same time, a client is created using the Erlang-Red MQTT nodes so that the broker implementation can be tested. Again a breadboard: thing of the MQTT nodes as an [oscilloscope](https://en.wikipedia.org/wiki/Oscilloscope) testing the voltage!

Development Strategy
---

My development process is best described as [flow driven development](DevelopmentStrategy.md) based around a set of [test flows](priv/testflows) to ensure that node functionality is implemented correctly - meaning that it matches the existing Node-RED functionality.

Test flows are mirrored in a separate [repository](https://github.com/gorenje/erlang-red-flow-testsuite) for better maintainability and also integration with existing Node-RED installations.

Architecture
----

Erlang architecture is best described by describing various use cases:

- Deploying [flows](https://flows.red-erik.org/f/2d51a745ca17dc05) to Erlang-Red. Explains the start up process and how Erlang processes are started for nodes.
- Workings of a [supervisor node](https://flows.red-erik.org/f/211405fa9e8a6f9b) supervising a function node.
- The challenges of [function node](https://flows.red-erik.org/f/1fd621a674360b5d) which must support timeouts, sub-processes and being supervised by a supervisor.
- Inner workings of [link nodes](https://flows.red-erik.org/f/43e8af136f4d0fbe) and how to deal with dynamic link calls.

Supported Nodes & Features
---

This is a non-complete list of [nodes](src/nodes/) that partially or completely work:

### Node-RED core nodes

| Node | Comment | Example Flow |
| ---- | ------- | ------------ |
| [batch](src/nodes/ered_node_batch.erl) | Mark messages as belonging to a batch and buffer messages until batches are completed. | [Flow](https://flows.red-erik.org/f/1658196c31549916) |
| [binary](src/nodes/ered_node_binary.erl) | parser and match binary data using [Packet]() definitions. | [Flow](https://flows.red-erik.org/f/fbd5864f413917b8) |
| [catch](src/nodes/ered_node_catch.erl) | catches exception of selected nodes and of entire flows but not groups | [Flow](https://flows.red-erik.org/f/71f65246c742cfc9) |
| [change](src/nodes/ered_node_change.erl) | supports many operators but not all. JSONata in basic form is also supported. | [Flow](https://flows.red-erik.org/f/12572f9ac11e1786) |
| [complete](src/nodes/ered_node_complete.erl) | is available and can be used on certain nodes, not all | [Flow](https://flows.red-erik.org/f/b723353a316fa50e) |
| [csv](src/nodes/ered_node_csv.erl) | initial RFC4180 decoder working, supports only comma separator | [Flow](https://flows.red-erik.org/f/16b0bc0cdb0c5807) |
| [debug](src/nodes/ered_node_debug.erl) | only debugs the entire message, individal msg properties aren't supported. msg count as status is supported. | [Flow](https://flows.red-erik.org/f/b2a67e301fabab0e) |
| [delay](src/nodes/ered_node_delay.erl) | supported static delay not dynamic delay set via `msg.delay` | [Flow](https://flows.red-erik.org/f/9d11bfc3a6d88535) |
| [exec](src/nodes/ered_node_exec.erl) | executing and killing commands is supported  but only for commands in spawn mode and set on the node. Appending arguments to commands isn't supported. Timeouts are supported. Kill messages are also supported. | [Flow](https://flows.red-erik.org/f/090eb2d5d71fd45f) |
| [file](src/nodes/ered_node_file.erl) | write and delete files anywhere on disk | TBD |
| [file in](src/nodes/ered_node_file_in.erl) | working for files located in `/priv` | [Flow](https://flows.red-erik.org/f/538be5947c639b32) |
| [filter](src/nodes/ered_node_rbe.erl) | Partially implemented. | [Flow](https://flows.red-erik.org/f/cef9dd7dc179b8b3) |
| [function](src/nodes/ered_node_function.erl) | working for any Erlang. Stop and start also respected. Timeout and more than one output port isn't supported. | [Flow](https://flows.red-erik.org/f/3bba732ae17b01a9) |
| [http in](src/nodes/ered_node_http_in.erl) | working for GET and POST, not available for PUT,DELETE etc | [Flow](https://flows.red-erik.org/f/64445798b59d2630) |
| [http request](src/nodes/ered_node_http_request.erl) | basic support for doing rrequests, anything complex probably won't work | [Flow](https://flows.red-erik.org/f/27804627fb8f56bd) |
| [http response](src/nodes/ered_node_http_response.erl) | working | [Flow](https://flows.red-erik.org/f/44f12f6e4a455084) |
| [i2c out](src/nodes/ered_node_i2c_out.erl) | Very initial and very basic I2C out node | [Flow](https://flows.red-erik.org/f/ea246f68766c8632) |
| [inject](src/nodes/ered_node_inject.erl) | working for most types except for flow, global ... | [Flow](https://flows.red-erik.org/f/7e1d04570c6bdff9) |
| [join](src/nodes/ered_node_join.erl) | *manual arrays of count X* is working, `parts` isn't supported  | [Flow](https://flows.red-erik.org/f/987cd33b9cda8529) |
| [json](src/nodes/ered_node_json.erl) | working | [Flow](https://flows.red-erik.org/f/c4690c0a085d6ef5) |
| [junction](src/nodes/ered_node_junction.erl) | working | [Flow](https://flows.red-erik.org/f/e1ced3b16782f7c8) |
| [link call](src/nodes/ered_node_link_call.erl) | working - dynamic & static calls and timeout is respected | [Flow](https://flows.red-erik.org/f/c6ee6e89a51c98fc) |
| [link in](src/nodes/ered_node_link_in.erl) | working | [Flow](https://flows.red-erik.org/f/8a627c9bfe3b4aff) |
| [link out](src/nodes/ered_node_link_out.erl) | working | [Flow](https://flows.red-erik.org/f/bbb1fc2d47c3cd5f) |
| [markdown](src/nodes/ered_node_markdown.erl) | working and supports whatever [earmark](https://github.com/pragdave/earmark) supports. | [Flow](https://flows.red-erik.org/f/90c1ce90f8af227f) |
| [mqtt in](src/nodes/ered_node_mqtt_in.erl) | should be working | [Flow](https://flows.red-erik.org/f/486c1412721bb241) |
| [mqtt out](src/nodes/ered_node_mqtt_out.erl) | should be working | [Flow](https://flows.red-erik.org/f/486c1412721bb241) |
| [noop](src/nodes/ered_node_noop.erl) | doing nothing is very much supported | [Flow](https://flows.red-erik.org/f/2c5903c9e50d0648) |
| [sort](src/nodes/ered_node_sort.erl) | basic sort function implemented | [Flow](https://flows.red-erik.org/f/b7ebaf91f4d66ab3) |
| [split](src/nodes/ered_node_split.erl) | splitting arrays into individual messages is supported, string, buffers and objects aren't. | [Flow](https://flows.red-erik.org/f/b1430ea37ba7cc19) |
| [status](src/nodes/ered_node_status.erl) | working | [Flow](https://flows.red-erik.org/f/a916165378c446e3) |
| [switch](src/nodes/ered_node_switch.erl) | most operators work along with basic JSONata expressions  | [Flow](https://flows.red-erik.org/f/3edda6bd788f88c2) |
| [tcp in](src/nodes/ered_node_tcp_in.erl) | Tcp in node supports starting a TCP/IP server listening on a specific port.  | [Flow](https://flows.red-erik.org/f/bff27e059752cb60) |
| [tcp out](src/nodes/ered_node_tcp_out.erl) | Tcp out node that currently only supports the reply-to node to respond to an existing tcp in connections.  | [Flow](https://flows.red-erik.org/f/bff27e059752cb60) |
| [tcp request](src/nodes/ered_node_tcp_request.erl) | Tcp request node for connecting and communicating with Tcp listners. | [Flow](https://flows.red-erik.org/f/84a5a362cafe703f) |
| [template](src/nodes/ered_node_template.erl) | mustache templating is working but parsing into JSON or YAML isn't supported | [Flow](https://flows.red-erik.org/f/3ed472eab9503b4f) |
| [trigger](src/nodes/ered_node_trigger.erl) | the default settings should work | [Flow](https://flows.red-erik.org/f/1566e453a88578a9) |


### Erlang specific nodes

These nodes represent specific Erlang features as nodes and as such, could be implemented in NodeJS to provide Node-RED with the same functionality.

| Node | Comment | Example Flow |
| ---- | ------- | ------------ |
| [event handler](src/nodes/ered_node_erleventhandler.erl) | Erlang-Red node for the Erlang [`gen_event`](https://www.erlang.org/doc/apps/stdlib/gen_event.html) behaviour. Supports both dynamic and static configuration of the event handler. | [Flow](https://flows.red-erik.org/f/5c8974f17ca70789) |
| [module](src/nodes/ered_node_erlmodule.erl) |  Erlang module for defining Erlang modules that can be used with the function, event handler and statemachine nodes. | [Flow](https://flows.red-erik.org/f/442b3bf0d630e21d) |
| [supervisor](src/nodes/ered_node_erlsupervisor.erl) | Erlang-only node that implements the [supervisor behaviour](https://www.erlang.org/doc/system/sup_princ.html). Supports supervising supervisors and ordering of processes (i.e. nodes) to ensure correct restart and shutdown sequences. | [Flow](https://flows.red-erik.org/f/83c5e1824f32abec) |
| [statemachine](src/nodes/ered_node_erlstatemachine.erl) | Implements the [`gen_statem`](https://www.erlang.org/doc/apps/stdlib/gen_statem.html) behaviour. Requires a [module node](src/nodes/ered_node_erlmodule.erl) to define the actions of the statemachine. | [Flow](https://flows.red-erik.org/f/5672fa442b2b881d) |
| [event handler](src/nodes/ered_node_erleventhandler.erl) | In conjunction with the module node, this node implements the [`gen_event`](https://www.erlang.org/doc/apps/stdlib/gen_event.html) behaviour. | [Flow](https://flows.red-erik.org/f/5c8974f17ca70789) |
| [generic server](src/nodes/ered_node_erlgenserver.erl) | Implements the [`gen_server`](https://www.erlang.org/doc/apps/stdlib/gen_server.html) behaviour. Requires a [module node](src/nodes/ered_node_erlmodule.erl) to define the actions of the server. | [Flow](https://flows.red-erik.org/f/38f712d367cecffa) |

These nodes can be installed using the corresponding Node-RED [node package](https://flows.nodered.org/node/@gregoriusrippenstein/erlang-red-supervisor-node). In Node-RED these nodes are placebos, doing nothing.

### Unit testing nodes

Nodes for ensuring truth in unit test flows.

| Node | Comment | Example Flow |
| ---- | ------- | ------------ |
| [assert failure](src/nodes/ered_node_assert_failure.erl) | Sending this node a message, will cause test failure. This node ensures certain pathways of a flow aren't reached by messages. | [Flow](https://flows.red-erik.org/f/2c1c291ec8466bfb) |
| [assert success](src/nodes/ered_node_assert_success.erl) | If this node isn't reached during a test run, then that test will failure. This node represents pathways that must be traversed. | [Flow](https://flows.red-erik.org/f/562c518969666f24) |
| [assert debug](src/nodes/ered_node_assert_debug.erl) | This node can be used to ensure that another node produces content for the debug panel. | [Flow](https://flows.red-erik.org/f/a6dc7002d0a8640e) |
| [assert status](src/nodes/ered_node_assert_status.erl) | Ensure that a node is assigned a specific status value.  | [Flow](https://flows.red-erik.org/f/700c94899fdd3334) |
| [assert values](src/nodes/ered_node_assert_values.erl) | Check specific values on the message object and ensure these are correct. | [Flow](https://flows.red-erik.org/f/0e54563ba63b1501) |

These nodes can be installed using the corresponding Node-RED [node package](https://flows.nodered.org/node/@gregoriusrippenstein/erlang-red-unittest).

### Contexts & JSONata

- Contexts are **not supported**, so there is no setting things on `flow`, `node` or `global`.
- [JSONata](https://jsonata.org) has been **partially implemented** by the [Erlang JSONata Parser](https://github.com/gorenje/erlang-red-jsonata).

Elixir & Erlang-Red
---

Elixir helpers can be added to [erlang-red-elixir-helpers](https://github.com/gorenje/erlang-red-elixir-helpers) repository.

There is nothing stopping anyone from creating a complete node in Elixir provided there is a Erlang "node-wrapper", i.e., a bit of Erlang code in the [src/nodes](src/nodes) directory that references the Elixir node.

The initial example [markdown node](https://github.com/gorenje/erlang-red/blob/42f10112baac5a5f916ecd805eafc87382632dec/src/nodes/ered_node_markdown.erl#L38) is an Erlang node that references Elixir code. I also wrote an Elixir wrapper function whereby I could have just as easily referenced Earmark directly from the Erlang code. That was a stylist choice.

I intend to use Elixir code for importing Elixir libraries to the project and less coding nodes in Elixir. I simply prefer Erlang syntax. But each to their own :)

Build
-----

    $ rebar3 get-deps && rebar3 compile

Test
-----

    $ rebar3 eunit

Development
---

    rebar3 shell --apps erlang_red

Open the Node-RED visual flow editor in a browser:

    open -a Firefox http://localhost:9090/node-red

Local development with Docker
---

I use docker to develop this so for me, the following works:

    git clone git@github.com:gorenje/erlang-red.git
    cd erlang-red

    docker run -it -v $(pwd)/erlang-red:/code -v $(pwd)/data:/data -p 8080:8080 -w /code --rm erlang bash

    ## inside docker shell:
    rebar3 shell --apps erlang_red

Then from the docker host machine, open a browser:

    open -a Firefox http://localhost:8080/node-red

That should display the Node-RED visual editor.

Release
---

A [release](https://github.com/gorenje/erlang-red/blob/3cf3b6a33b59a808ffc865b008c8ee47a4437412/rebar.config#L35-L60) can be bundled together:

    $ rebar3 as prod release -n erlang_red

All static frontend code (for the Node-RED flow editor) and the test flow files in `priv/testflows` are bundled into the release.

Cowboy server will started on port 8080 unless the `PORT` env variable is set.

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


Example
---

![img](.images/erlang-red.gif)

What the gif shows is executing a [simple flow](https://flowhub.org/f/ea246f68766c8630) using Erlang as a backend. The flow demonstrates the difference in the switch node of 'check all' or 'stop at first match'.

All nodes are are processes- that is shown on the left in the terminal window.

This example is extremely trivial but it does lay the groundwork for expansion.

Testing
---

To create unit tests for this, Node-RED frontend has been extended with a
"Create Test Case" button on the export dialog:

![img](.images/create-test-case.png)

Test flows are stored in the [testflows](priv/testflows) directory and will be picked up the next time `make eunit-test` is called. In this way it is possible to create unit tests visually.

Flow tests can also be tested within the flow editor, for more details see below.

The flow test suite is now maintained in a [separate](https://github.com/gorenje/erlang-red-flow-testsuite) repository but is duplicated here.

Assert Nodes
---

To better support testing of flows, two new nodes have been created:

![img](.images/assert-nodes.png)

"Assert Failed" node cases unit tests to fail if a message reaches it, regardless of any message values. It's basically the same as a `assert(false)` call. The intention is to ensure that specific parts of a flow aren't reached.

The second node (in green) is an equivalent to a change node except it contains test on attributes of the message object. Possible tests include 'equal', 'match', 'unset' and the respective inverses. Here the intention is that a message passes through is tested for specific values else the unit test fails.

These nodes are necessary since there is no other way to test whether flow is working or not.

Also remember these flow tests are designed to ensure the Erlang backend is correctly implementing node functionality. The purpose of these nodes is *not* to ensure that a flow is correct, rather that the *functionality* of implemented nodes works and continues to work correctly.

Visual Unit Testing
---

My plan is to create test flows that represent specific NodeRED functionality that needs to be implemented by Erlang-Red. This provides regression testing and todos for the implementation.

I created a keyboard shortcut for creating and storing these test flows from the flow editor directly. However I was still use the terminal to execute tests `make eunit-test` - which  became painful. So instead I pulled this testing into Node-RED, as the gif demonstrates:

![img](.images/unit-testing-inside-nodered.gif)

What the gif shows is my list of unit tests, which at the press of a button, can all be tested. Notifications for each test shows the result. In addition, the tree list shows which tests failed/succeed (red 'x' or green check). Also tests can be executed individually so that failures can be checked individually.

The best bit though is that all errors are pushed to the debug panel and from there I get directly to the node causing the error. Visual unit testing is completely integrated into Erlang-Red.

My intention is to create many small flows that represent functionality that needs to be implemented by Erlang-Red. These unit tests shows the compatibility to Node-RED and less the correctness of the Erlang code.

Contributing
---

Contributions very much welcome in the form of Erlang code or as Node-RED test-flows, ideally with the Erlang implementation. Elixir code is also welcome, only it has its own [home](https://github.com/gorenje/erlang-red-elixir-helpers).

Each test flow should test exactly one feature and use the assert nodes to check correctness of expected results. Tests can also be pending to indicate that the corresponding Erlang functionality is still missing.


Sibling Repos
---

An overview of the sibling projects for both the reader and me:

- [Unit test flow suite](https://github.com/gorenje/erlang-red-flow-testsuite) provides *visual* unit tests that verify the functionality being implemented here is the same as in Node-RED. Those test flows are designed to be executed in both Node-RED and Erlang-Red. [FlowHub.org](https://flowhub.org) maintains the repository and is used to synchronise flow tests between Erlang-Red and Node-RED. These tests can also be used for other projects that aim to replicate Node-RED functionality in an alternative programming language.
- [Node-RED and Erlang-Red unit testing nodes](https://github.com/gorenje/erlang-red-unittesting-nodes) are used to define and automatically ensure the correct functionality. These nodes are embedded in test flows and ensure that test flows are correct. This makes testing repeatable and reliable and fast! As an aside, these nodes are maintained in an [Node-RED flow](https://flowhub.org/f/ef91cb280e1bfd72).
- [JSONata support for Erlang-Red](https://github.com/gorenje/erlang-red-jsonata) is implemented by an Erlang parser with a grammer that covers most of JSONata syntax, no guarantees made. Support of JSONata functionality is limited to what the test flows require. Nothing prevents others from extending the functionality themselves, it is not a priority of mine.
- [Elixir helper library](https://github.com/gorenje/erlang-red-elixir-helpers) allows Elixir code to be also part of Erlang-Red. Erlang-Red is not intended to be a *pure* Erlang project, it is intended to be a *pure* BEAM project. Anything that compiles down to the BEAM VM, why not include it?
- [Supervisor nodes](https://github.com/gorenje/erlang-red-supervisor-node) and other Erlang behaviours as Node-RED nodes. Node package includes `gen_statem` and `gen_event` as nodes that can be used with Erlang-Red flows. These nodes can also be installed into Node-RED but there they do nothing.
- [Type parsers](https://github.com/gorenje/erlang-red-type-parsers) for parsing specific Node-RED types such as Number or Buffer. Also for handling attribute access of maps and arrays.

FAQs
---

Questions and Answers at either the [Erlang Forum](https://erlangforums.com/t/erlang-red-erlang-interpreter-for-node-red-flow-code-visual-flow-based-programming/4678) or the [Node-RED Forum](https://discourse.nodered.org/t/erlang-red-erlang-backed-node-red/96458).

Also for more details, there was also a discussion on [Hacker News](https://news.ycombinator.com/item?id=44006231).

Acknowledgement
---

[Nick](https://github.com/knolleary) and [Dave](https://github.com/dceejay) for bring Node-RED to live - amazing quality and flexibility and the entire [Node-RED community](https://discourse.nodered.org/).

Much thanks to

- [@mwmiller](https://github.com/mwmiller) for providing a fly server for running a [live version](https://ered.fly.dev/node-red) of Erlang-Red,
- [@joaohf](https://erlangforums.com/u/joaohf/summary) many tips on coding Erlang and structuring an Erlang project, and
- [@Maria-12648430](https://erlangforums.com/u/maria-12648430/summary) for debugging my initial attempt to create a gen_server for nodes.
- [@joergen7](https://github.com/joergen7) for the Erlang insights and explaining dialyzer to me and the importance of clean code
- [@vkatsuba](https://erlangforums.com/u/vkatsuba/summary) for the [great tips](https://erlangforums.com/t/efficient-storage-using-lists/4988/4?u=gorenje) on using ETS tables for buffering messages

License Smorgasbord
---

This offers multi-licensing smorgasbord to pick the license that best meets your needs:

- if you wish to do evil and are not concerned with the impact of your behaviour (probably because you gain a financial reward from said behaviour), then you want to using the [apache-2](LICENSE.ap2) license.

- if your concerned about the impact of closed source software and the erosion of the commons of shared knowledge, then you might consider the [gpl](LICENSE.gpl) license

- if you're planning to do good, for example, for educational purposes and provide others with the knowledge to make informed decisions, then you might want to consider the [don't do evil](LICENSE.dde) license

Human Intelligence
---

No Artificial Intelligence was harmed in the creation of this codebase. This codebase is old skool search engine (ddg), stackoverflow, blog posts and RTFM technology.

AI contributions can be made according to the rules defined in [.aiignore](.aiignore).
