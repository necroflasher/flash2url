flash2url

it reads a .swf file from stdin, then serves it to standalone flash player (or
 whatever command you enter) using a temporary http server

the file is served as it's read from stdin without any buffering*, so
 preloaders work as expected

* lie, it does buffer until the first frame is fully downloaded because the
 flash player will give up if it's not received within one second (flash2url
 has a workaround to extend this to 10 seconds with the buffering thing)

example:

  # simulate slow load
  pv -q -L 1200K ./file.swf 2>/dev/null | flash2url flashplayer

  # load resources relative to the .swf from another site
  flash2url -baseurl=http://example.org/some_path/ flashplayer <./file.swf

note: flashes opened from a url are a bit different from those opened from disk:
- they can open links in the browser without asking
- they can use the internet
- (maybe more?)
