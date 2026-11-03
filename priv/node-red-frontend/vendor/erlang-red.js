window.ErlangRED = (function(){
    //
    // Used to highlight the links in markdown text - links that highlight
    // nodes in the flow. This is used for documentational purposes, see
    // https://discourse.nodered.org/t/highlighting-nodes-and-groups-from-the-info-text-box/84020
    // for details
    //
    function handleTextReferences() {
        var getDataIds = (ele) => {
            return ($(ele).data("ids") || $(ele).data("id") || "").split(",");
        };

        var setHrefClass = (ele) => {
            $(ele).attr('href', '#');
            $(ele).addClass('ahl');
        };

        var nodesInGrp = (grpId) => {
            var ndeIds = []
            let ndsInGrp = RED.nodes.group(grpId) || { nodes: [] }
            ndsInGrp.nodes.forEach( n => {
                if ( n.type == "group" ) {
                    ndeIds = ndeIds.concat( nodesInGrp(n.id) )
                } else {
                    ndeIds.push(n.id)
                }
            })
            return ndeIds
        };

        var highlightNodes = (ndeIds) => {
            // move the workspace to the first node of
            // the group but don't make the highlight blink
            RED.view.reveal(ndeIds[0], false)
            RED.view.redraw();

            RED.tray.hide();
            RED.view.selectNodes({
                selected: ndeIds,
                onselect: function(selection) { RED.tray.show(); },
                oncancel: function() { RED.tray.show(); }
            });
        };

        $('a.ahl-node-only').each(function (idx, ele) {
            setHrefClass(ele);
            $(ele).removeClass('ahl-node-only');
            $(ele).css('color', '#f4a0a0')

            var ndeIds = getDataIds(ele);

            $(ele).on('click', function (e) {
                if ( ndeIds.length == 1 ) {
                    RED.view.reveal(ndeIds[0], true)
                    RED.view.redraw();
                } else {
                    highlightNodes(ndeIds)
                }
            });
        });

        $('a.ahl-group-only').each(function (idx, ele) {
            setHrefClass(ele);
            $(ele).removeClass('ahl-group-only');
            $(ele).css('color', '#f4a0a0')

            // here the ids are group ides, need to find all nodes in those
            // groups and highlight them
            var grpIds = getDataIds(ele);
            var ndeIds = []
            grpIds.forEach( grpId => {
                ndeIds = ndeIds.concat( nodesInGrp( grpId ) )
            })

            $(ele).on('click', function (e) {
                if ( ndeIds.length == 1 ) {
                    RED.view.reveal(ndeIds[0], true)
                    RED.view.redraw();
                } else {
                    highlightNodes(ndeIds)
                }
            });
        });

        $('a.ahl-link-node').each(function (idx, ele) {
            setHrefClass(ele);
            $(ele).removeClass('ahl-link-node');
            $(ele).css('color', '#f4a0a0')

            var ndeIds = getDataIds(ele);

            $(ele).on('click', function (e) {
                if ( ndeIds.length == 1 ) {
                    RED.view.reveal(ndeIds[0], true)
                    RED.view.redraw();
                } else {
                    highlightNodes(ndeIds)
                }
            });
        });
    }

    let customDropHandler = async (event) => {
        /* because this handler is assigned to multiple elements, the same event
           may be handled multiple times. Prevent that. */
        if ( window.ddEvents.map(d => d.timeStamp).includes(event.timeStamp)) { return }
        window.ddEvents = [event].concat(window.ddEvents)
        window.ddEvents.length = 10

        if ( !event.originalEvent || !event.originalEvent.dataTransfer) { return }

        let itemPtr = event.originalEvent.dataTransfer.items
        let itemCount = itemPtr.length

        let stringKindsStoredForLater = {}
        let isThisABookmarkImport = false
        const bookmarkTypes = [
            "text/x-moz-place",
            "text/x-moz-url",
            "text/uri-list"
        ]

        let importNewNodes = (nde) => {
            return RED.view.importNodes(Array.isArray(nde) ? nde : [nde])
        }

        let handleSearchResult = (data) => {
            try {
                let nodeId = data.content.match(/><div class="red-ui-search-result-node-id">([^<]+)<\/div>/)[1];

                if (nodeId) {
                    let node = RED.nodes.node(nodeId);
                    if (node && (node.type != "tab" && node.type != "group")) {
                        RED.view.importNodes(
                            RED.nodes.convertNode(node), {
                                generateIds: true,
                                generateDefaultNames: false,
                                touchImport: false
                        })
                        return true
                    }
                }
            } catch(e) {}
            return false
        }

        let storeStringKind = async (itm, evnt) => {
            return new Promise((resolve, reject) => {
                itm.getAsString((content) => {
                    isThisABookmarkImport = isThisABookmarkImport || bookmarkTypes.indexOf(itm.type) > -1

                    let data = {
                        type: itm.type,
                        content: content,
                        event: evnt,
                        lines: (content || "").split("\n").filter(d => !!d)
                    };

                    (stringKindsStoredForLater[data.type] ||= []).push(data);
                    stringKindsStoredForLater[data.type].sort((a, b) => a.lines.length > b.lines.length ? -1 : 1)

                    resolve()
                })
            })
        }

        for (let idx = 0; idx < itemCount; idx++) {
            let itm = itemPtr[idx]

            if (itm.kind == "file" && event.originalEvent && event.originalEvent.dataTransfer) {
                /* ignore */
            } else if (itm.kind == "string") {
                // we do this because a bookmark has - up to - three different items
                // representing the same URL. What we do is filter by url and only
                // import that URL once. I.e. dragging and dropping a bookmark into
                // Node-RED will - potentially - generate 5 (in Firefox) items of types:
                //   - text/uri-list
                //   - text/x-moz-url
                //   - text/plain
                //   - text/html
                //   - text/x-moz-place
                // Potentially there are more.
                await storeStringKind(itm, event.originalEvent)
            } else {
                console.log(`Ignoring unsupported drag&drop kind: '${itm.kind}'`)
                RED.notify(`Dropped item kind "${itm.kind}" is not supported.`, { type: "warning" })
            }
        }

        if (isThisABookmarkImport) {
            if ("text/html" in stringKindsStoredForLater &&
                stringKindsStoredForLater["text/html"][0].content.match(/red-ui-search-result-node-id/) &&
                handleSearchResult(stringKindsStoredForLater["text/html"][0]) ) {
                // done but do something
                1 == 1
            } else if ("text/x-moz-place" in stringKindsStoredForLater) {
                /* ignore */
            } else if ("text/x-moz-url" in stringKindsStoredForLater) {
                /* ignore */
            } else if ("text/uri-list" in stringKindsStoredForLater) {
                /* ignore */
            }
        }
    }

    function defineCustomDropHandler() {
        if ($('#red-ui-drop-target').length > 0) {
            $('#red-ui-drop-target').on("drop", customDropHandler)

            /* this prevents drops from leaving the editor and opening new pages */
            $(window).on("dragover", (e) => { e.preventDefault()})
            $(document).on("dragover", (e) => { e.preventDefault() })

            $(window).on("drop", customDropHandler)
            $(document).on("drop", (e) => { e.preventDefault() })
        } else {
            setTimeout(defineCustomDropHandler, 300)
        }
    }

    function capturePreFlightAjaxCalls() {

        function hostForToken(token) {
            if (token && token.startsWith("local://")) {
                return token.replace(/^local:\/\//, "").split("?")[0]
            } else {
                return "https://api.flowhub.org/"
            }
        }

        function compareFlows(msg) {
          var oldFlowRevision = {};
          var newFlowRevision = {};

          for (var idx = 0; idx < msg.payload.length; idx++) {
            oldFlowRevision[msg.payload[idx].id] = msg.payload[idx]
          }

          for (var idx = 0; idx < msg.new_flowdata.length; idx++) {
            newFlowRevision[msg.new_flowdata[idx].id] = msg.new_flowdata[idx]
          }

          var changes = []

          /* nodes that have been deleted */
          for (var idx = 0; idx < msg.payload.length; idx++) {
            var oldObj = msg.payload[idx];

            if (!newFlowRevision[oldObj.id]) {
              changes.push({
                type: "deleted",
                id: oldObj.id,
                oldObj: oldObj,
                newObj: undefined
              })
            }
          }

          for (var idx = 0; idx < msg.new_flowdata.length; idx++) {
            var newObj = msg.new_flowdata[idx];
            var oldObj = oldFlowRevision[newObj.id];

            if (!oldObj) {
              changes.push({
                type: "added",
                id: newObj.id,
                oldObj: undefined,
                newObj: newObj
              })
            } else {
              if (JSON.stringify(oldObj) != JSON.stringify(newObj)) {
                changes.push({
                  type: "changed",
                  id: newObj.id,
                  oldObj: oldObj,
                  newObj: newObj
                })
              }
            }
          }

          return changes;
        }


        $.ajaxPrefilter(function( options, originalOptions, jqXHR ) {
            let mth = undefined;

            // Encode the original flow data into a base64 string. Why?
            // To preserve object key ordering in the backend. Erlangs json:decode
            // has the feature of ordering keys alphabetically, JS does not
            // and unfortunately neither does the backend of FlowHub.
            // So to maintain the original key ordering as found here, we
            // avoid decoding the JSON until it reaches the FlowHub backend.
            mth = options.url.match(/^FlowHubPush/i)
            let isDiff = options.url.match(/^FlowHubDiff$/i)
            if (mth || isDiff) {
                // https://developer.mozilla.org/en-US/docs/Glossary/Base64#the_unicode_problem
                function bytesToBase64(bytes) {
                    const binString = String.fromCodePoint(...bytes);
                    return btoa(binString);
                }

                let dd = JSON.parse(options.data)
                dd.c64fd = bytesToBase64(new TextEncoder().encode(
                    JSON.stringify(dd.flowdata)
                ))
                options.data = JSON.stringify(dd)
            }

            // handle the FlowCompare functionality locally since we store
            // the flow data on deploy - extract what is being compared from there.
            mth = options.url.match(/^FlowCompareCfg/i)
            if ( mth ) {
                var data = JSON.parse( options.data )
                var lcl = JSON.parse( RED.settings.getLocal("flowdata"))

                var lclnodes = []
                lcl.flows.forEach( nde => {
                    if ( nde.id == data.flowid || nde.z == data.flowid ) {
                        lclnodes.push(nde)
                    }
                })

                options.success({
                    "status": "ok",
                    "flowid": data.flowid,
                    "nodes": lclnodes,
                    "changes": compareFlows({
                        payload: lclnodes,
                        new_flowdata: data.flowdata
                    })
                })

                jqXHR.abort();
            }

            // Message tracer add websocket name to the request
            mth = options.url.match(/^MsgTracer/i)
            if ( mth ) {
               let hsh = JSON.parse(options.data)
               hsh["wsname"] = document.cookie.split("=")[1]
               options.data = JSON.stringify(hsh)
            }
        })
    }

    return {
        init: () => {
            defineCustomDropHandler()
            capturePreFlightAjaxCalls()

            RED.events.on( 'markdown:rendered', () => {
                setTimeout( () => {
                    handleTextReferences()
                },1000)
            })
        }
    };
})();

let initOrSleep = () => {
    if (typeof(RED) == undefined) {
        setTimeout(initOrSleep, 300)
    } else {
        ErlangRED.init()
    }
}

window.ddEvents = []
setTimeout(initOrSleep, 300)
