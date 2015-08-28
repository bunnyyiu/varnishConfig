# This is a basic VCL configuration file for varnish.  See the vcl(7)
# man page for details on VCL syntax and semantics.

# Default backend definition.  Set this to point to your content
# server.

backend default {
  .host = "127.0.0.1";
  .port = "8088";
}

acl purge {
  "localhost";
  "127.0.0.1";
}

sub vcl_recv {
  if (req.restarts == 0) {
   	if (req.http.x-forwarded-for) {
 	    set req.http.X-Forwarded-For = req.http.X-Forwarded-For + ", " + client.ip;
 	  } else {
 	    set req.http.X-Forwarded-For = client.ip;
 	  }
  }
  if (req.http.X-Http-Method-Override == "FETCH") {
    set req.request = "FETCH";
    unset req.http.X-Http-Method-Override;
  }
  if (req.request != "GET" &&
      req.request != "HEAD" &&
      req.request != "PUT" &&
      req.request != "POST" &&
      req.request != "TRACE" &&
      req.request != "OPTIONS" &&
      req.request != "DELETE" &&
      # PURGE and FETCH are special requests
      req.request != "PURGE" &&
      req.request != "FETCH") {
         /* Non-RFC2616 or CONNECT which is weird. */
    return (pipe);
  }
  if (req.request != "GET" &&
      req.request != "HEAD" &&
      req.request != "PURGE" &&
      req.request != "FETCH") {
    return (pass);
  }
  if (!(req.url ~ "wp-(login|admin)") &&
      !(req.url ~ "&preview=true") &&
      !(req.http.Cookie ~ "wordpress_logged_in")) {
    unset req.http.cookie;
  }
  if (req.http.Authorization || req.http.Cookie) {
    /* Not cacheable by default */
    return (pass);
  }

  if (req.request == "PURGE" || req.request == "FETCH") {
    if (!client.ip ~ purge) {
      set req.request = "GET";
      error 405 "Not allowed.";
    }
  }

  if (req.request == "FETCH") {
    set req.http.X-Fetch = "YES";
  }

  if (req.request == "PURGE") {
    set req.http.X-Purge = "YES";
  }

  return (lookup);
}

sub vcl_pipe {
  # Note that only the first request to the backend will have
  # X-Forwarded-For set.  If you use X-Forwarded-For and want to
  # have it set for all requests, make sure to have:
  # set bereq.http.connection = "close";
  # here.  It is not set by default as it might break some broken web
  # applications, like IIS with NTLM authentication.
  return (pipe);
}

sub vcl_pass {
  return (pass);
}

sub vcl_hash {
  hash_data(req.url);
  if (req.http.host) {
    hash_data(req.http.host);
  } else {
    hash_data(server.ip);
  }
  return (hash);
}

sub vcl_hit {
  if (req.request == "PURGE") {
    purge;
    error 200 "Purged.";
  }
  if (req.request == "FETCH") {
    purge;
    # Due to a bug #1361, we cannnot call restart here, so we call restart in vcl_error
    return (error);
  }
  return (deliver);
}

sub vcl_miss {
  if (req.request == "PURGE") {
    purge;
    error 200 "Purged.";
  }
  if (req.request == "FETCH") {
    purge;
    # Due to a bug #1361, we cannnot call restart here, so we call restart in vcl_error
    return (error);
  }
  return (fetch);
}

sub vcl_fetch {
  if (!(req.url ~ "wp-(login|admin)")) {
    unset beresp.http.set-cookie;
    set beresp.ttl = 1w;
  }

  if (beresp.ttl <= 0s ||
      beresp.http.Set-Cookie ||
      beresp.http.Vary == "*") {
	 /*
    * Mark as "Hit-For-Pass" for the next 2 minutes
    */
    set beresp.ttl = 120 s;
    return (hit_for_pass);
  }
  return (deliver);
}

sub vcl_deliver {
  if (obj.hits > 0) {
    set resp.http.X-Cache = "HIT";
  } else {
    set resp.http.X-Cache = "MISS";
  }

  if (req.http.X-Fetch == "YES") {
    unset req.http.X-Fetch;
    set resp.http.X-Fetch = "YES";
  }

  if (req.http.X-Purge == "YES") {
    unset req.http.X-Purge;
    set resp.http.X-Purge = "YES";
  }
  return (deliver);
}

sub vcl_error {
  # call restart if it is FETCH
  if (req.request == "FETCH" && req.restarts == 0) {
    set req.request = "GET";
    return(restart);
  }
  set obj.http.Content-Type = "text/html; charset=utf-8";
  set obj.http.Retry-After = "5";
  synthetic {"
  <?xml version="1.0" encoding="utf-8"?>
  <!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN"
   "http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd">
  <html>
    <head>
      <title>"} + obj.status + " " + obj.response + {"</title>
    </head>
    <body>
      <h1>Error "} + obj.status + " " + obj.response + {"</h1>
      <p>"} + obj.response + {"</p>
      <h3>Guru Meditation:</h3>
      <p>XID: "} + req.xid + {"</p>
      <hr>
      <p>Varnish cache server</p>
    </body>
  </html>
  "};
  return (deliver);
}

sub vcl_init {
 	return (ok);
}

sub vcl_fini {
 	return (ok);
}
