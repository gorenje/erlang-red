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

    return {
        init: () => {
            defineCustomDropHandler()

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
