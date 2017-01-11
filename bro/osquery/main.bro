
module osquery;

export {
	## The osquery logging stream identifier.
	redef enum Log::ID += { LOG };

	## Type defining the type of osquery change we are interested in.
	type UpdateType: enum {
		ADD,	##< Report new elements.
		REMOVE,	##< Report removed element.
		BOTH	##< Report both new and removed elements.
	};

	## Type defining a single event to subscribe to.
	type Event: record {
		## The Bro event to execute when receiving updates.
		ev: any &optional;
		## The osquery SQL query selecting the activity to subscribe to.
		query: string;
		## The type of update to report.
		utype: UpdateType &default=BOTH;
		## If true, report all current elements once at connecting to client.
		init_dump: bool &default=F;
	};

	## Subscribe to an event from clients. Whenever an osquery client
	## connects to us, we'll subscribe to all matching activity from it.
	##
	## ev: The event to subscribe to.
	##
	## net: IP space this subscription applies to. If a client outside of
	## this range connects, the subscription won't be applied to it.
	global subscribe: function(ev: Event, net: subnet &default=0.0.0.0/0);

	## Unsubscribe to an event from clients. This will get sent to all clients
  ## that are currently connected and would match a similar subscribe
  ## call.
	##
	## ev: The event to unsubscribe from.
	##
	## net: IP space this unsubscription applies to.
  global unsubscribe: function(ev: Event, net: subnet &default=0.0.0.0/0);

	## Subscribe to multiple events. Whenever an osquery client connects to us, we'll
	## subscribe to all matching activity from it.
	##
	## ev: The events to subscribe to.
	##
	## net: IP space this subscription applies to. If a client outside of this range
	## connects, the subscriptions won't be applied to it.
	global subscribe_multiple: function(evs: vector of Event, net: subnet &default=0.0.0.0/0);

	## Unsubscribe from multiple events. This will get sent to all clients
        ## that are currently connected and would match a similar subscribe
        ## call.
	##
	## ev: The events to unsubscribe from.
	##
	## net: IP space this unsubscription applies to.
  global unsubscribe_multiple: function(evs: vector of Event, net: subnet &default=0.0.0.0/0);

  ## Associate a group with a host. This will tell the host to post to a
  ## corresponding group topic. The local Bro will automatically subscribe to that,
  ## but other receivers potentially talking to the same host will ignore the
  ## activity. 
	global set_host_group: function(peer_name: string, group: string);

	## Event that signals the connection of a new osquery host
	##
	## client_id: An id that uniquely identifies an osquery host 
  ## addr_list: A list of IP addresses of that osquery host
  global new_osquery_host: event(client_id: string, addr_list: vector of addr);

	# Event sent by clients to report an error.
	#
	# TODO: Add peer_name.
	global host_error: event(peer_name: string, msg: string);

	# Event sent by clients to report a warning.
	#
	# TODO: Add peer_name.
	global host_warning: event(peer_name: string, msg: string);

	# Event sent by clients to report an informational log message.
	#
	# TODO: Add peer_name.
	global host_log: event(peer_name: string, msg: string);

	## A record type containing the column fields of the osquery log.
	type Info: record {
		## The network time at which a osquery activity occurred.
		ts:                  time   &log;
		## ``bro`` or ``osquery`` depending on whether Bro generated the
		## message locally, or an osquery host sent it.
		source: string &log;
		## The peer name (if any) with which a communication event is
		## concerned.
		peer:                string &log &optional;
		## The severity of the communication event message.
		level:               string &log &optional;
		## The main log message.
		message:             string &log;
	};


}

# Sent by us to the client for subscribing to an event.
global host_subscribe: event(ev: string, query: string, utype: string, initdump: bool);


# Sent by us to the client for unsubscribing from an event.
global host_unsubscribe: event(ev: string, query: string, utype: string, initdump: bool);

:
# Sent by us to set the topic for the client to publish its events with.
global host_set_topic: event(topic: string);

# A new osquery host announced that it is now available and awaiting orders
# Hosts will include their random/unique ID, such that a dedicated channel is available for each host
global new_osquery_host: event(uid: string);

# Internal record for tracking a subscription.
type Subscription: record {
	net: subnet;
	ev: Event;
};

global hosts:set[string, vector of addr];
#global hosts: set[addr, string]; # All currently connected and "ready" osquery clients.
global subscriptions: vector of Subscription;
global groups: set[string];
global host_groups: table[string] of string &default="default";

function log_host(level: string, peer: string, msg: string)
	{
	Log::write(osquery::LOG, [$ts = network_time(),
				  $level = level,
				  $source = "osquery",
				  $peer = peer,
				  $message = msg]);
	}

function log_peer(level: string, peer: string, msg: string)
	{
	Log::write(osquery::LOG, [$ts = network_time(),
				  $level = level,
				  $source = "bro",
				  $peer = peer,
				  $message = msg]);
	}

function log_local(level: string, msg: string)
	{
	Log::write(osquery::LOG, [$ts = network_time(),
				  $level = level,
				  $source = "bro",
				  $peer = "localhost",
				  $message = msg]);
	}

function send_subscribe(client_id: string, ev: Event)
  {
	local init_dump = ev$init_dump;
	local ev_name = split_string(fmt("%s", ev$ev), /\n/)[0];
	local host_topic = fmt("/osquery/uid/%s", client_id);
	
	log_peer("info", client_id, fmt("%s event %s() with '%s'",
					"subscribing to", ev_name, ev$query));

	local update_type = "BOTH";

	if ( ev$utype == ADD )
		update_type = "ADD";

	if ( ev$utype == REMOVE )
		update_type = "REMOVED";

	local ev_args = Broker::event_args(host_subscribe, ev_name, ev$query, update_type, init_dump)
	Broker::send_event(host_topic, ev_args);
  } 

function send_unsubscribe(peer_name: string, ev: Event)
	{
	local init_dump = ev$init_dump;
	local ev_name = split_string(fmt("%s", ev$ev), /\n/)[0];
	local host_topic = fmt("/bro/osquery/host/%s", peer_name);
	
	log_peer("info", peer_name, fmt("%s event %s() with '%s'",
					"unsubscribing from", ev_name, ev$query));

	local update_type = "BOTH";

	if ( ev$utype == ADD )
		update_type = "ADD";

	if ( ev$utype == REMOVE )
		update_type = "REMOVED";

	local ev_args = Broker::event_args(host_unsubscribe, ev_name, ev$query, update_type, init_dump);
	Broker::send_event(host_topic, ev_args);
	}

function same_event(ev1: Event, ev2: Event) : bool
	{
	return fmt("%s", ev1$ev) == fmt("%s", ev2$ev) && ev1$query == ev2$query &&
	       ev1$utype == ev2$utype && ev1$init_dump == ev2$init_dump;
	}

function subscribe(ev: Event, net: subnet)
	{
	subscriptions[|subscriptions|] = [$net=net, $ev=ev];

	# Subscribe from current clients.
  for ( [ip, peer_name] in hosts ) 
		{
		if ( ip !in net )
			next;
		
		send_subscribe(peer_name, ev);
		}
	}

function unsubscribe(ev: Event, net: subnet)
	{
	for ( i in subscriptions )
		{
		if ( same_event(subscriptions[i]$ev, ev) )
			# Don't have a delete for vector, so set it to no-op
      # by leaving the event empty.
      subscriptions[i]$ev = [$query=""];
		}

	# Unsubscribe from current clients.
  for ( [ip, peer_name] in hosts ) 
		{
		if ( ip !in net )
			next;
		
		send_unsubscribe(peer_name, ev);
		}
	}

function subscribe_multiple(evs: vector of Event, net: subnet)
	{
	for ( i in evs )
		subscribe(evs[i], net);
	}

function unsubscribe_multiple(evs: vector of Event, net: subnet)
	{
	for ( i in evs )
		unsubscribe(evs[i], net);
	}

function send_subscriptions(client_id: string)
	{
	for ( i in subscriptions )
		{
		local s = subscriptions[i];

		if ( ! s?$ev )
			next;

    for ( ip in hosts[client_id]) 
      {
      if ( ip in s$net ) 
        {
	      send_subscribe(client_id, s$ev);
        break;
        }
      }
		}
	}

function set_host_group(peer_name: string, group: string)
	{
	if ( group !in groups )
		{
		local topic = fmt("/bro/osquery/group/%s", group);
		log_local("info", fmt("subscribing to topic %s", topic));
		Broker::subscribe_to_events(topic);
		add groups[group];
		}

	host_groups[peer_name] = group;
	}

event bro_init()
	{
	Log::create_stream(LOG, [$columns=Info, $path="osquery"]);

	# TODO: Not sure this should stay here. We still need to figure out a way
	# for different applications to use Broker jointly without messing up
	# whatever another one is doing.
	Broker::enable();

	local topic = "/bro/osquery/group/default";
	log_local("info", fmt("subscribing to topic %s", topic));
	Broker::subscribe_to_events(topic);

	Broker::listen(9999/tcp, "0.0.0.0");
	}

event host_log(peer_name: string, msg: string)
	{
	log_host("info", peer_name, msg);
	}

event host_warning(peer_name: string, msg: string)
	{
	log_host("warning", peer_name, msg);
	}

event host_error(peer_name: string, msg: string)
	{
	log_host("error", peer_name, msg);
	}

event new_osquery_host(client_id: string, addr_list: vector of addr)
{
  print "Received new announce message with uid ", client_id;
	log_peer("info", peer_name, "new osquery host");

  # Hosts can post query results via an individual topic
	local host_topic = fmt("/osquery/uid/%s", client_id);
  Broker::subscribe_to_events(host_topic);

	local ip = to_addr(peer_addr);
	add hosts[client_id, addr_list];
	send_subscriptions(ip);
}

event Broker::incoming_connection_established(peer_name: string)
	{
	log_peer("info", peer_name, "incoming connection established");
	}

event Broker::connection_incoming_connection_broken(peer_name: string)
	{
	local ip = to_addr(peer_name);
	delete hosts[ip, peer_name];
	}