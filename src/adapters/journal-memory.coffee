transaction = deepCopy = null

module.exports = (racer) ->
  {transaction} = racer
  {deepCopy} = racer.util
  racer.adapters.journal.Memory = JournalMemory

JournalMemory = ->
  @flush()
  return

JournalMemory::=
  flush: (callback) ->
    @_txns = []
    @_txnClock = {}
    @_startId = (+new Date).toString 36
    callback? null

  startId: (callback) -> callback @_startId

  version: (callback) -> callback null, @_txns.length

  unregisterClient: (clientId, callback) ->
    delete @_txnClock[clientId]
    callback?()

  txnsSince: (ver, clientId, pubSub, callback) ->
    since = []
    return callback null, since unless pubSub.hasSubscriptions clientId

    txns = @_txns
    while txn = txns[ver++]
      if pubSub.subscribedTo clientId, transaction.path(txn)
        since.push txn
    callback null, since

  nextTxnNum: (clientId, callback) ->
    txnClock = @_txnClock
    num = txnClock[clientId] = (txnClock[clientId] || 0) + 1
    callback null, num

  commitFn: (store, mode) -> commitFns[mode] this, store


commit = (txns, store, txn, callback) ->
  journalTxn = JSON.parse JSON.stringify txn
  ver = txns.push journalTxn
  transaction.base journalTxn, ver
  store._finishCommit txn, ver, callback

commitFns =
  lww: (self, store) -> (txn, callback) ->
    commit self._txns, store, txn, callback

  stm: (self, store) -> (txn, callback) ->
    ver = transaction.base txn
    txns = self._txns
    if ver?
      if typeof ver isnt 'number'
        # In case of something like store.set(path, value, callback)
        return callback? new Error 'Version must be null or a number'

      while item = txns[ver++]
        if err = transaction.conflict txn, item
          return callback? err

    commit txns, store, txn, callback
