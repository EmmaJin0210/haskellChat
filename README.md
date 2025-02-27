# HaskChat

## Authors

Ruikun(Harry) Hao, harryhao

Ming Hao, mhao

Emma Jin, mqjin

## Setup

run:

```bash
stack build
```

## ChatServer

The ChatServer is a distributed server with FIFO ordering and fault tolerance, ensuring reliable communication in distributed environments. The functionalities are modularly organized across three main files: ChatServer.hs contains the core server logic including FIFO multicast and retransmission handling; FrontendHandler.hs manages client interactions like room joining and message relaying; and Utils.hs provides auxiliary utilities for server configuration and network operations.

The address configurations of the server are specified in server_list.txt, which looks something like this:

```plaintext
127.0.0.1:3000,127.0.0.1:4000
127.0.0.1:3001,127.0.0.1:4001
127.0.0.1:3002,127.0.0.1:4002
```
The first address of each line is the forwarding port, or proxy port --- when the proxy is open and useProxy is set to True, servers utilize this port to communicate to each other.
The second address of each line is the binding port, which is the port clients connect to when joining a server.

To run a server in the terminal, do:

```bash
stack exec chatserver -- <port> <useProxy: True|False> <serverListFile>
```

For example, to run 3 separate servers on ports 4000, 4001, and 4002 without Proxy, do (in separate terminals):

```bash
stack exec chatserver -- 4000 False server_list.txt
```

```bash
stack exec chatserver -- 4001 False server_list.txt
```

```bash
stack exec chatserver -- 4002 False server_list.txt
```

To run with the proxy, set useProxy to True, for example:

```bash
stack exec chatserver -- 4000 True server_list.txt
```

You do not need to modify the port in the command line to use the proxy, just keep it as the binding port.

## Proxy

The Proxy component is a critical intermediary for testing the correctness of our chat server. As we are running our chat servers on the same machine, it is difficult to produce interesting scenarios for testing our message ordering and fault tolerance. Therefore, we need a proxy to simulate realistic network conditions like message delays and packet loss (which will not happen on a single machine). The proxy operates by receiving messages from servers, applying a random delay or packet drop (based on the max delay and loss probability configured), and then forwarding them to their intended destinations.

To run the proxy in the terminal, do:

```bash
stack exec proxy <serverListFile> [-d maxDelayMicroseconds] [-l lossProbability]
```

For example,

```bash
stack exec proxy -- server_list.txt -d 3000000 -l 0.1
```

## Loadbalancer

We made a loadbalancer to direct a user (web frontend client) to a chat server. It will always pick the server node with the lowest load.

```bash
stack exec loadbalancer server_list.txt
```

Then the loadbalancer is listening for HTTP request on `localhost:8080`

## Web Frontend

An interactive chat UI running on browser. We used Haskell frontend framework [Miso](https://haskell-miso.org/). The code is adapted from official example in Miso git repo.

```bash
stack exec frontend
```
Then you can acess our frontend on `localhost:8081`

### To Join a Room

run

```bash
/join <room-number>
```

in the client terminal.

### To Send a Message

Type text into the client terminal. The message should be multicasted to the client itself and well as any other clients in the same room.
