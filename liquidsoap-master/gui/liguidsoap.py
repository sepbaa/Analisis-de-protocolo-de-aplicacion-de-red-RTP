#!/usr/bin/env python

import pygtk
pygtk.require('2.0')
import gtk
import gobject

import socket, sys, os, time, re
from subprocess import Popen, PIPE
import getopt

from client import LiqClient
from widgets import View

from queue import LiqQueue
from editable import LiqEditable
from playlist import LiqPlaylist
from mix import LiqMix
from output import LiqOutput

class LiqGui(gtk.Notebook):
  def __init__(self,host='localhost',port=1234):
    gtk.Notebook.__init__(self)
    self.set_show_tabs(False)

    self.host=host
    self.port=port
    self.tel = LiqClient(host,port)
    self.list = View([['type','80'],['name','100']],[])
    self.list.connect('row_activated',self.row_activated)
    box = gtk.HBox()
    box.pack_start(self.list,False,False)
    lbl = gtk.Label()
    lbl.set_markup("""
<b>The Savonet Team is happy to welcome you in liguidsoap.</b>

On the left is a list of controllable nodes. Double-click a row to open the controller.

The <b>output</b> nodes are those which do something with your stream.
Some output directly to your speakers, some save your stream to a file, and 
finally, some output to an icecast server for webradio.

A <b>mixer</b> is a mixing table. It has some input sources, and allows you 
to select which one you want to play, tune the volume, etc.

<b>editable</b> and <b>queue</b> nodes are interactive playlists, in which
you can add files using drag-n-drop or builtin file browser. The editable is 
more powerful, allows you to delete, insert at any place, not only at the 
bottom.

Finally, a <b>playlist</b> is a non-interactive playlist, which list and 
behaviour is hard-coded in the liquidsoap script. You can just see what will be 
played next. (Actually, more could be coming soon, like changing random mode 
and playlist file...)

Liquidsoap and liguidsoap are copyright (c) 2003-2020 Savonet Team.
This is free software, released under the terms of GPL version 2 or higher.
""")
    box.pack_start(lbl)
    self.append_page(box,gtk.Label('list'))
    box.show() ; lbl.show()
    self.list.show()
    self.show()
    gobject.timeout_add(1000,self.update)

  def update(self):
    def hashof(s):
      m = re.search('(\S+)\s:\s(\S+)',s)
      return { 'name' : m.group(1), 'type' : m.group(2) }
    list = [ hashof(s) for s in
             filter(lambda x: x!='',
                    re.compile('\n').split(self.tel.command('list'))) ]
    self.list.setModel(list)

  def row_activated(self,view,path,column):
    type = view.get_model().get_value(view.get_model().get_iter(path),0)
    name = view.get_model().get_value(view.get_model().get_iter(path),1)
    b = gtk.HBox()
    l = gtk.Label(name+' ')
    c = gtk.Button('x') # TODO stock close
    c.n = self.get_n_pages()
    b.pack_start(l)
    b.pack_start(c)
    c.show() ; l.show()
    def clicked(w):
      self.remove_page(w.n) # TODO cleanup contents (especially telnet)
    c.connect('clicked',clicked)
    self.set_show_tabs(True)
    # This is a dirty workaround, we should not show this item
    # in the first place!
    if type=='interactive':
      print("Unsupported item...")
    else:
      self.append_page(
          {'queue'   : lambda x: LiqQueue(self.host,self.port,x),
           'editable': lambda x: LiqEditable(self.host,self.port,x),
           'playlist': lambda x: LiqPlaylist(self.host,self.port,x),
           'mixer'   : lambda x: LiqMix(self.host,self.port,x),
           'output.icecast': lambda x: LiqOutput(self.host,self.port,x),
           'output.file'   : lambda x: LiqOutput(self.host,self.port,x),
           'output.oss'    : lambda x: LiqOutput(self.host,self.port,x),
           'output.ao'     : lambda x: LiqOutput(self.host,self.port,x),
           'output.alsa'   : lambda x: LiqOutput(self.host,self.port,x),
           'output.portaudio': lambda x: LiqOutput(self.host,self.port,x),
           'output.pulseaudio': lambda x: LiqOutput(self.host,self.port,x),
           'output.dummy'  : lambda x: LiqOutput(self.host,self.port,x),
          }[type](name),b)

# Now is the big deal: how to start liguidsoap,
# configuration dialog and automatic liquidsoap launch.

# liquidsoap runs liquidsoap with a fixed script
# a few parameters are available
def liquidsoap(
    enable_mic=False,
    host='localhost',port=1234,mount='emission.ogg',
    backup=''):
  if backup=='':
    addbackup=""
  else:
    addbackup=';"backup"'

  enable_mic_str = "false"
  if enable_mic:
    enable_mic_str = "true"

  script = """
set("log.file",true)
set("log.file.path","/tmp/lig.<pid>.log")
set("log.stdout",true)
set("server.telnet",true)

bg = request.equeue(id="bed")
music = request.equeue(id="music")
sfx = request.equeue(id="sfx")

enable_mic = %s
sources =
  if enable_mic then
    [(in(id="microphone"):source),music,bg,sfx]
  else
    [music,bg,sfx]
  end
mixer = mix(id="mixer",sources)

output.prefered(id="speaker",mixer)
output.icecast(%%vorbis,
  id="broadcast",
  host="%s",port=%d,mount="%s",start=false,mixer)
output.file(%%vorbis,id="backup",start=false,"%s",mixer)
""" % (enable_mic_str, host, port, mount, backup)

  binary = Popen("which liquidsoap",
             stdout=PIPE,shell=True).stdout.read()[0:-1]
  if binary=="":
    print "Cannot find liquidsoap binary in $PATH!"
    exit(1)

  print "Excuting %s with the following script:" % binary
  print "=== BEGIN ==="
  print script
  print "=== END ==="
  pid = os.fork()
  if pid==0:
    os.execl(binary,"liquidsoap",script)
  else:
    return pid

# liguidsoap is the toplevel call, starts everything
def liguidsoap():
  try:
    opts, args = getopt.gnu_getopt(sys.argv[1:],"h:p:",['host=','port='])
  except:
    print 'Usage: %s [OPTIONS]...' % sys.argv[0]
    print 'Options are:'
    print '  -h,--host=HOST'
    print '  -p,--port=PORT'
    sys.exit()

  host=None
  port=1234
  for o , a in opts:
    if o in ('-p', '--port'):
      port=int(a)
    if o in ('-h', '--host'):
      host=a

  ehost=eport=erun=dialog=None
  icehost=iceport=icemount=backup=None

  def exit(pid):
    if pid!=None:
      os.kill(pid,15)
      os.waitpid(pid,0)
    gtk.main_quit()

  # This startup function can be used to start the GUI directly
  # or after user input in dialog
  def start(response=None):
    # Dialog stuff
    liquid_pid=None
    if response!=None:
      if response!=gtk.RESPONSE_ACCEPT:
        sys.exit()
      if erun.get_active():
        host,port = 'localhost',1234
        liquid_pid=liquidsoap(
            enable_mic=enable_mic.get_active(),
            host=icehost.get_text(),
            port=iceport.get_value(),
            mount=icemount.get_text(),
            backup=backup.get_text())
	# This could be tighter...
        print "Waiting 3 seconds for liquidsoap to start..."
        time.sleep(3)
      else:
        host=ehost.get_text()
        port=int(eport.get_value())
      dialog.destroy()

    # Startup
    win = gtk.Window()
    win.set_border_width(10)
    win.connect("delete_event", lambda w,e: False)
    win.connect("destroy", lambda osb: exit(liquid_pid))
    win.set_title('Liquidsoap on '+host+':'+str(port))
    win.resize(700,300)
    try:
      win.add(LiqGui(host,port))
    except socket.error, x:
      error = gtk.MessageDialog(message_format=
          ("Couln't connect to "+host+' on port '+str(port)+'!'))
      # TODO there's a strange cursor in the message
      error.connect("response",gtk.main_quit)
      error.show()
      return
    win.show()

  # If no host has been given on command-line, use the dialog
  if host==None:
    dialog = gtk.Dialog(
        "LiGUIdsoap",None,0,
        (gtk.STOCK_CANCEL, gtk.RESPONSE_CANCEL,
          gtk.STOCK_OK, gtk.RESPONSE_ACCEPT,))
    dialog.connect("response",lambda d,id: start(id))

    table = gtk.Table(2,2)
    table.show()
    dialog.vbox.pack_start(table)

    ehost = gtk.Entry()
    ehost.set_text('localhost')
    ehost.show()
    lbl = gtk.Label("Host: ")
    lbl.show()
    table.attach(lbl,0,1,0,1)
    table.attach(ehost,1,2,0,1)

    eport = gtk.SpinButton()
    eport.set_range(0,99999)
    eport.set_increments(1,10)
    eport.set_value(port)
    eport.show()
    lbl = gtk.Label("Port: ")
    lbl.show()
    table.attach(lbl,0,1,1,2)
    table.attach(eport,1,2,1,2)

    # Settings for automatic liquidsoap run
    erunconf = gtk.Table(2,7)

    enable_mic = gtk.CheckButton("Use microphone input (may not be functional)")
    enable_mic.show()
    erunconf.attach(enable_mic,0,2,0,1)

    lbl = gtk.Label("Icecast settings")
    erunconf.attach(lbl,0,2,1,2) ; lbl.show()

    icehost = gtk.Entry()
    icehost.set_text('localhost')
    lbl = gtk.Label("Host: ")
    erunconf.attach(lbl,0,1,2,3)
    erunconf.attach(icehost,1,2,2,3)
    lbl.show() ; icehost.show()

    iceport = gtk.SpinButton()
    iceport.set_range(0,99999)
    iceport.set_increments(1,10)
    iceport.set_value(8000)
    iceport.show()
    lbl = gtk.Label("Port: ")
    lbl.show()
    erunconf.attach(lbl,0,1,3,4)
    erunconf.attach(iceport,1,2,3,4)

    icemount = gtk.Entry()
    icemount.set_text('emission.ogg')
    lbl = gtk.Label("Mount: ")
    erunconf.attach(lbl,0,1,4,5)
    erunconf.attach(icemount,1,2,4,5)
    lbl.show() ; icemount.show()

    lbl = gtk.Label("Local backup OGG file")
    erunconf.attach(lbl,0,2,5,6)
    backup = gtk.Entry()
    backup.set_text('/tmp/emission.ogg')
    erunconf.attach(backup,0,2,6,7)
    backup.show() ; lbl.show()

    erun = gtk.CheckButton("Run liquidsoap automatically")
    erun.show()
    dialog.vbox.pack_start(erun)
    dialog.vbox.pack_start(erunconf)
    def erunclicked(w):
      if erun.get_active():
        erunconf.show()
      else:
        erunconf.hide()
    erun.connect("clicked", erunclicked)

    dialog.show()

  # Otherwise, start directly
  else:
    start()

  gtk.main()

if __name__=='__main__':
  liguidsoap()
