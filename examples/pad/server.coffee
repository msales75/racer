express = require 'express'
gzip = require 'connect-gzip'
fs = require 'fs'
racer = require 'racer'

app = express.createServer()
  .use(express.favicon())
  .use(gzip.staticGzip(__dirname))

# Listen specifies a port or http server
# Namespace specifies the Socket.IO namespace
store = racer.createStore redis: {db: 11}, listen: app, namespace: 'pad'
# Clear all existing data on restart
store.flush()

# racer.js returns a browserify bundle of the racer client side code and the
# socket.io client side code as well as any additional browserify options
racer.js require: './node_modules/racer/node_modules/share/lib/types/helpers.js', minify: false, entry: __dirname + '/client.js', (js) ->
  fs.writeFileSync __dirname + '/script.js', js

app.get '/', (req, res) ->
  res.redirect '/racer'

app.get '/:group', (req, res) ->
  model = store.createModel()
  model.subscribe "groups.#{req.params.group}", (room) ->
    model.ref '_room', room
    room.otNull 'text', 'Edit this with friends.'
    # model.bundle waits for any pending model operations to complete and then
    # returns the JSON data for initialization on the client
    model.bundle (bundle) ->
      res.send """
      <!DOCTYPE html>
      <title>Pad</title>
      <link rel=stylesheet href=style.css>
      <body>
      <div id=editor-container>
        <textarea id=editor>#{room.get 'text'}</textarea>
      </div>
      <script>init=#{bundle}</script>
      <script src=script.js></script>
      """

app.listen 3011
console.log 'Go to http://localhost:3011/racer'
