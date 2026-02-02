# flash2url

**flash2url** is a tool for serving `.swf` files from a temporary URL.
It can be used with the Flash&nbsp;Player to open flashes from disk as
if they were loaded from a website.

The program reads its input from [`stdin`][stdin], so it can also be
used to [pipe][] or "stream" flashes to the player in a way that lets
[preloaders][] work. Buffering of the file is kept to a minimum with
this use case in mind.

[stdin]: https://en.wikipedia.org/wiki/Standard_streams#Standard_input_(stdin)
[pipe]: https://en.wikipedia.org/wiki/Pipeline_(Unix)
[preloaders]: # "Loading screens that display while the flash is downloaded, often customized for the flash."

## Examples

-   **Simulate a slow connection (with [pv][]):**

        pv -q -L 1200K ./file.swf 2>/dev/null | flash2url flashplayer

-   **Load resources relative to the `.swf` from another site:**

        flash2url -baseurl=http://example.org/some_path/ flashplayer <./file.swf

    With this command, a request to e.g. `data.xml` next to the `.swf`
    file would be redirected to
    <NOBR>`http://example.org/some_path/data.xml`</NOBR>.

-   **Load resources relative to the `.swf` from the filesystem:**

        flash2url -basedir=./flashfiles flashplayer <./file.swf

    This is similar to the example using `-baseurl=`, with the
    difference that resources are loaded from a directory instead of a URL.

-   **Specify the filename/path:**

    By default, the flash is served as `file.swf` or an auto-detected
    file name. To customize this, use the `-filename=` option:

        flash2url -filename=notfile.swf flashplayer <./file.swf

    Tip: The name is allowed to contain slashes (`/`). This can be used
    if the URL of the flash needs to contain a specific directory path.

[pv]: https://ivarch.com/programs/pv.shtml

## Limitations

-   Files are served from `127.0.0.1` ([localhost][]). Flashes that are
    "site-locked" to only work on a specific domain might refuse to
    work.

-   The server is single-threaded and can only serve one request at a
    time. If the flash takes a long time to load, this will delay other
    requests until it's done. (Requests to other Internet sites are not
    affected.)

[localhost]: https://en.wikipedia.org/wiki/Localhost

## Good to know

Flashes loaded from a URL use a different mode of the
[security sandbox][sb] than those loaded from disk. The main difference
is that network access is allowed by default while access to local files
is disallowed.

<S>Because URL-loaded flashes are allowed network access, they're also
able to download [SWZ files][swz]. These contain library code from Adobe
and are required for some flashes to work. If you open such a flash from
disk without its required SWZ file(s) already downloaded, the player is
unable to fetch them and thus the file will fail to play.

<SMALL>(todo: can non-URL flashes download them in the "local with
networking" sandbox mode?)</SMALL></S>

This section is under construction. Do SWZ downloads work at all
anymore?

[sb]: https://airsdk.dev/docs/development/security/security-sandboxes
[swz]: https://flex.apache.org/doc/flex/using/flx_rsl_rsl.html

## Implementation notes

### Timeout extension trick

There's a little trick that the built-in web server in flash2url
implements to extend the Flash&nbsp;Player's timeout for loading a flash
from one second to 10.

Normally, when you point the player at a URL, it has a timeout of **one
second** to receive enough data to display the first frame of the flash.
If the timeout is exceeded, the player gives up trying to load the movie
and presents you with a blank screen.

The result is that with a slow connection, you might find that badly
engineered flashes which pack all their resources into the first frame
are impossible to open with the standalone player.

The key to solving this is that there seems to be a separate, longer
timeout when waiting for the response from the HTTP server to begin.
This is a generous 10 seconds. A typical web server will begin its
response immediately, so normally, you would rarely see the effect of
this longer timeout.

flash2url, with its custom web server, can take advantage of this. The
trick is to buffer the flash (read it without sending anything to the
player yet) until it can parse the first `ShowFrame` tag. Only after the
first frame is complete, the embedded web server begins its response and
starts sending the `.swf` to the player.

The difference is invisible to the user since the player normally
doesn't display anything before the first frame is loaded.

### Correct HTTP `Content-Length` for compressed flashes

[Preloaders][] typically work by comparing
[`LoaderInfo.bytesLoaded`][bl] against [`LoaderInfo.bytesTotal`][bt]. In
flashes loaded from a URL, the value of the latter comes from the
[<NOBR>`Content-Length`</NOBR> header][cl] that the HTTP server sent.
(It can thus be said that a correct <NOBR>`Content-Length`</NOBR> is
essential to displaying preloaders correctly.)

When flash2url gets a `.swf` file from a [pipe][] like in some of the
[examples](#examples) above, how does it know what to send as the
<NOBR>`Content-Length`</NOBR> if it only has access to a stream of
bytes? Remember that we need to support preloaders, so waiting to read
the stream to completion is not an option.

For those flashes that don't use compression, there's a fairly simple
solution - [the header of every `.swf` file][swfheader] contains a file
size number that's just the right value for this. We can hold off
sending the <NOBR>`Content-Length`</NOBR> until we've read the beginning
of the file with the header, and then send it along with the right
<NOBR>`Content-Length`</NOBR> value.

However, for a compressed flash, what can we do?
<NOBR>`Content-Length`</NOBR> represents the size of the HTTP response
body (in this case, a compressed `.swf` file) but the size in the file
header is for an uncompressed version. The sizes naturally won't match.

The answer is to transparently decompress the flash and serve an
uncompressed version to the player. flash2url parses the flash, undoing
compression and puts together a brand new uncompressed version on the
fly for sending to the client. The size in the header is specified to be
correct after decompression - so with this trick, we can use it for
flashes that were originally compressed as well.

[cl]: https://developer.mozilla.org/docs/Web/HTTP/Reference/Headers/Content-Length
[bl]: https://airsdk.dev/reference/actionscript/3.0/flash/display/LoaderInfo.html#bytesLoaded
[bt]: https://airsdk.dev/reference/actionscript/3.0/flash/display/LoaderInfo.html#bytesTotal
[swfheader]: https://www.m2osw.com/swf_tag_file_header

## This pic was in the repo

`youtuberip with the circle preloader.png`

![](media/youtuberip%20with%20the%20circle%20preloader.png)
