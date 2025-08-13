#!/bin/bash
#
# retrieve.sh
#
# Author: Gerrit Riessen, gerrit@openmindmap.org
# Copyright (C) 2023-2025 Gerrit Riessen
# This code is licensed under the GNU Public License.
#
# $Id$
#

# This script will retrieve certain configuration files from an existing
# node red instance and copy these here. It retrieves:
#
#   - icons configuration and all icons
#   - nodes configuration .json, .html and locales
#   - plugin configuration .json, .html and locales
#   - locales in the locales directory
#
# other things will need to be updated manually.

### TODO change the following.
# NODERED_URL=http://nodered-host:1880/httpAdminRoot

NODERED_URL=http://renderbox:1890/cfg

### TODO remove this also
#echo "Edit retrieve.sh before use"
#exit

CBSTMP=$(date +%s)
PyTHON=/usr/bin/python3

echo "==> html, javascript & css"

mkdir -p settings nodes debug/view

curl -s "${NODERED_URL}/favicon.ico?_=${CBSTMP}" -o favicon.ico

##
## These are all text files.
##
for fle in vendor/jquery/css/base/jquery-ui.min.css \
           vendor/jquery/css/base/images/ui-icons_777777_256x240.png \
           vendor/font-awesome/css/font-awesome.min.css \
           vendor/monaco/style.css \
           vendor/monaco/dist/editor.js \
           vendor/monaco/dist/8f3abbcbc983396e1f13.ttf \
           vendor/monaco/dist/editor.worker.js \
           vendor/monaco/dist/ts.worker.js \
           vendor/monaco/dist/html.worker.js \
           vendor/monaco/dist/json.worker.js \
           vendor/monaco/dist/css.worker.js \
           vendor/monaco/monaco-bootstrap.js \
           vendor/vendor.js \
           vendor/font-awesome/fonts/fontawesome-webfont.ttf \
           vendor/font-awesome/fonts/fontawesome-webfont.woff2 \
           vendor/font-awesome/fonts/fontawesome-webfont.woff \
           vendor/mermaid/mermaid.min.js \
           vendor/purify.min.js.map \
           red/main.min.js \
           red/tours/welcome.js \
           red/images/deploy-full.svg \
           red/images/deploy-full-o.svg \
           red/images/deploy-flows.svg \
           red/images/deploy-flows-o.svg \
           red/images/deploy-nodes.svg \
           red/images/deploy-nodes-o.svg \
           red/images/deploy-reload.svg \
           red/images/grip.svg \
           red/images/grip-horizontal.svg \
           red/images/node-red.svg \
           red/images/node-red-icon-black.svg \
           red/images/spin.svg \
           red/images/subflow_tab.svg \
           red/images/typedInput/az.svg \
           red/images/typedInput/09.svg \
           red/images/typedInput/bool.svg \
           red/images/typedInput/json.svg \
           red/images/typedInput/bin.svg \
           red/images/typedInput/expr.svg \
           red/images/typedInput/env.svg \
           types/node-red/util.d.ts \
           types/node-red/func.d.ts \
           types/node/globals.d.ts \
           types/node/console.d.ts \
           types/node/buffer.d.ts \
           types/node/timers.d.ts \
           types/node/util.d.ts \
          ; do
    mkdir -p $(dirname $fle)
    curl -s "${NODERED_URL}/${fle}?v=${CBSTMP}" > ${fle}
done

##
## these two should only be retrieved once since they will be altered
##
#curl -s "${NODERED_URL}/?_=${CBSTMP}" -H 'Accept: application/html' -o index.html
#curl -s "${NODERED_URL}/red/red.js?_=${CBSTMP}" -o red/red.js
#curl -s "${NODERED_URL}/red/style.min.css?_=${CBSTMP}" -o red/style.min.css
#curl -s "${NODERED_URL}/settings/user?_=${CBSTMP}" -o settings/user.json
#curl -s "${NODERED_URL}/theme?_=${CBSTMP}" -o theme
#curl -s "${NODERED_URL}/red/keymap.json?_=${CBSTMP}" -o red/keymap.json
#curl -s "${NODERED_URL}/settings?_=${CBSTMP}" -o settings.json

#curl -s "${NODERED_URL}/debug/view/debug-utils.js?_=${CBSTMP}" -o debug/view/debug-utils.js

#curl -s "${NODERED_URL}/nodes?_=${CBSTMP}" -H 'Accept: text/html' > nodes/nodes.html
#curl -s "${NODERED_URL}/plugins?_=${CBSTMP}" -H 'Accept: text/html' > plugins/plugins.html

LoCaLeS="en-US en-GB en de-DE de fr ja ko pt-BR ru zh-CN zh-TW"

echo "==> icons.json"
curl -s "${NODERED_URL}/icons?_=${CBSTMP}" -H 'Accept: application/json' | $PyTHON .py/json_pretty.py > icons.json

for lnk in `cat icons.json | $PyTHON .py/icon_urls.py` ; do
    echo "==> ${lnk}"
    mkdir -p `dirname ${lnk}`
    curl -s ${NODERED_URL}/${lnk} > ${lnk}
done

for typ in nodes plugins ; do

    mkdir -p ${typ}

    for lng in ${LoCaLeS} ; do
        echo "==> ${typ}/messages/${lng}"
        curl -s "${NODERED_URL}/${typ}/messages?lng=${lng}&_=${CBSTMP}" | $PyTHON .py/json_pretty.py > ${typ}/messages.${lng}
    done
    cp ${typ}/messages.en-US ${typ}/messages

    echo "==> ${typ}/${typ}.json"
    curl -s "${NODERED_URL}/${typ}?_=${CBSTMP}" -H 'Accept: application/json' | $PyTHON .py/json_pretty.py > ${typ}/${typ}.json

    # if [ "${typ}" != "nodes" ] ; then
    #   echo "==> ${typ}/${typ}.html"
    #   curl -s "${NODERED_URL}/${typ}?_=${CBSTMP}" -H 'Accept: text/html' > ${typ}/${typ}.html
    # fi
done

for lcls in editor infotips node-red jsonata ; do
    mkdir -p locales

    for lng in ${LoCaLeS} ; do
        echo "==> locales/${lcls}/${lng}"
        curl -s "${NODERED_URL}/locales/${lcls}?lng=${lng}" | $PyTHON .py/json_pretty.py > locales/${lcls}.${lng}
    done
done
