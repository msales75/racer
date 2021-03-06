# Transactions are represented as an Array:
# [ base = version at the time of the transaction
# , transaction id
# , method
# , arguments]

module.exports =
  create: (obj) ->
    if obj.ops
      txn = [obj.base, obj.id, obj.ops]
    else
      txn = [obj.base, obj.id, obj.method, obj.args]
    return txn

  base: (txn, val) ->
    txn[0] = val if val isnt undefined
    return txn[0]

  id: (txn, val) ->
    txn[1] = val if val isnt undefined
    return txn[1]

  clientIdAndVer: (txn) ->
    res = @id(txn).split '.'
    res[1] = parseInt res[1], 10
    return res

  method: (txn, name) ->
    txn[2] = name if name isnt undefined
    return txn[2]

  args: (txn, vals) ->
    txn[3] = vals if vals isnt undefined
    return txn[3]

  path: (txn, val) ->
    args = @args txn
    args[0] = val if val isnt undefined
    return args[0]

  meta: (txn, vals) ->
    txn[4] = vals if vals isnt undefined
    return txn[4]

  clientId: (txn, newClientId) ->
    [clientId, num] = @id(txn).split '.'
    if newClientId isnt undefined
      @id(txn, newClientId + '.' + num)
      return newClientId
    return clientId

  pathConflict: (pathA, pathB) ->
    # Paths conflict if equal or either is a sub-path of the other
    return 'equal' if pathA == pathB
    pathALen = pathA.length
    pathBLen = pathB.length
    return false if pathALen == pathBLen
    if pathALen > pathBLen
      return pathA.charAt(pathBLen) == '.' && pathA[0...pathBLen] == pathB && 'child'
    return pathB.charAt(pathALen) == '.' && pathB[0...pathALen] == pathA && 'parent'

  ops: (txn, ops) ->
    txn[2] = ops unless ops is undefined
    return txn[2]

  isCompound: (txn) ->
    return Array.isArray txn[2]

  op:
    create: (obj) ->
      op = [obj.method, obj.args]
      return op

    method: (op, name) ->
      op[0] = name if name isnt undefined
      return op[0]

    args: (op, vals) ->
      if vals isnt undefined
        op[1] = vals
      return op[1]
