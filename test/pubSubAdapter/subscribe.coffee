{expect} = require '../util'

module.exports = (getStore) ->

  onMessage = (callback) ->
    pubSub = getStore()._pubSub
    # Remove listeners that may have been created by Store, since we are just
    # testing the functionality of the pubSub adapter itself
    pubSub.removeAllListeners()
    pubSub.on 'message', callback  if callback?
    return pubSub

  it 'a published transaction to the same path should be received if subscribed to', (done) ->
    pubSub = onMessage (subscriberId, message) ->
      expect(subscriberId).to.equal '1'
      expect(message).to.eql 'value'
      done()
    pubSub.subscribe '1', ['channel'], ->
      pubSub.publish 'channel', 'value'

  it 'a published transaction to a subpath should be received if subscribed to', (done) ->
    pubSub = onMessage (subscriberId, message) ->
      expect(subscriberId).to.equal '1'
      expect(message).to.equal 'value'
      done()

    pubSub.subscribe '1', ['channel'], ->
      # Should match
      pubSub.publish 'channel.1', 'value'
      # Should not match
      pubSub.publish 'channel1', 'value'

  it 'a published transaction to a patterned `prefix.*.suffix` path should only be received if subscribed to', (done) ->
    counter = 0
    expected = ['valueA1', 'valueA2']
    pubSub = onMessage (subscriberId, message) ->
      expect(subscriberId).to.equal '1'
      expect(message).to.equal expected[counter++]
      done() if counter == 2

    pubSub.subscribe '1', ['channel.*.suffix'], ->
      pubSub.publish 'channel.1.suffix', 'valueA1'
      pubSub.publish 'channel.1.nomatch', 'valueB'
      pubSub.publish 'channel.1.suffix', 'valueA2'

  it 'unsubscribing from a path means the subscriber should no longer receive the path messages', (done) ->
    counter = 0
    pubSub = onMessage (subscriberId, message) ->
      counter++
      if message == 'last'
        expect(counter).to.equal 3
        done()

    pubSub.subscribe '1', ['a', 'b'], ->
      pubSub.publish 'a', 'first'
      pubSub.publish 'b', 'second'
      setTimeout ->
        pubSub.unsubscribe '1', ['a'], ->
          pubSub.publish 'a', 'ignored'
          pubSub.publish 'b', 'last'
      , 50

  it 'unsubscribing from a path you are not subscribed to should be harmless', (done) ->
    pubSub = onMessage()
    pubSub.unsubscribe 'subcriber', ['not-subscribed-to-this-channel']
    done()

  it 'unsubscribing from a pattern means the subscriber should no longer receive the pattern messages', (done) ->
    counter = 0
    pubSub = onMessage (subscriberId, message) ->
      counter++
      if message == 'last'
        expect(counter).to.equal 3
        done()

    pubSub.subscribe '1', ['a.*', 'b.*'], ->
      pubSub.publish 'a.1', 'first'
      pubSub.publish 'b.1', 'second'
      setTimeout ->
        pubSub.unsubscribe '1', ['a.*'], ->
          pubSub.publish 'a.2', 'ignored'
          pubSub.publish 'b.2', 'last'
      , 50

  it 'subscribing > 1 time to the same path should still only result in the subscriber receiving the message once', (done) ->
    counter = 0
    pubSub = onMessage (subscriberId, message) ->
      counter++
      if message == 'last'
        expect(counter).to.equal 2
        done()

    pubSub.subscribe '1', ['channel'], ->
      pubSub.subscribe '1', ['channel'], ->
        pubSub.publish 'channel', 'first'
        pubSub.publish 'channel', 'last'

  it 'subscribing > 1 time to the same pattern should still only result in the subscriber receiving the message once', (done) ->
    counter = 0
    pubSub = onMessage (subscriberId, message) ->
      counter++
      if message == 'last'
        expect(counter).to.equal 2
        done()

    pubSub.subscribe '1', ['channel'], ->
      pubSub.subscribe '1', ['channel'], ->
        pubSub.publish 'channel.1', 'first'
        pubSub.publish 'channel.1', 'last'

  it 'overlapping patterns are expected to duplicate callbacks', (done) ->
    counter = 0
    pubSub = onMessage (subscriberId, message) ->
      counter++
      if message == 'two'
        expect(counter).to.equal 3
        done()

    pubSub.subscribe '1', ['channel'], ->
      pubSub.subscribe '1', ['channel.1'], ->
        pubSub.publish 'channel.1', 'one'
        pubSub.publish 'channel.2', 'two'

  it '2 subscribers to the same pattern should both receive messages', (done) ->
    counter = 2
    subscribersWithReceipt = {}
    pubSub = onMessage (subscriberId, message) ->
      subscribersWithReceipt[subscriberId] = true
      return if --counter
      expect(subscribersWithReceipt).to.eql '1': true, '2': true
      done()

    pubSub.subscribe '1', ['channel.*'], ->
      pubSub.subscribe '2', ['channel.*'], ->
        pubSub.publish 'channel.1', 'value'

  it 'subscribedToTxn should test if a client id is subscribed to a given transaction', ->
    pubSub = onMessage()
    subscriber = '100'
    pubSub.subscribe subscriber, ['b'], ->
      expect(pubSub.subscribedTo subscriber, 'a.b.c').to.be.false
      expect(pubSub.subscribedTo subscriber, 'b').to.be.true
      expect(pubSub.subscribedTo subscriber, 'b.c.d').to.be.true
