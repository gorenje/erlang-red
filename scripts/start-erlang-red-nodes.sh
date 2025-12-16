#!/bin/bash

NODE_COUNT=${1:-1}

tmux new-session -d -s erlang-red

for i in `seq 0 $NODE_COUNT`; do
  tmux split-window -t erlang-red:0 -v
  tmux send-keys -t erlang-red:0.$i "NODE_NAME=node_$i PORT=808$i ../_build/default/rel/erlang_red/bin/erlang_red console" C-m
  sleep 1
done

echo tmux attach -t erlang-red
