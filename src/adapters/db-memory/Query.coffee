{mergeAll, deepCopy} = require '../../util'
{lookup, assign} = require '../../path'
Promise = require '../../Promise'
LiveQuery = require '../../pubSub/LiveQuery'

module.exports = MemoryQuery = ->
  LiveQuery.apply this, arguments
  @_conds = {}
  @_opts = {}
  return

MemoryQuery::= mergeAll {}, LiveQuery::,
  only: (paths...) ->
    @_selectType = 'only'
    fields = @_opts.fields ||= {}
    fields[path] = 1 for path in paths
    return this

  except: (paths...) ->
    @_selectType = 'except'
    fields = @_opts.fields ||= {}
    fields[path] = 0 for path in paths
    return this

  skip: (skip) ->
    @_opts.skip = skip
    return this

  limit: (limit) ->
    @_opts.limit = limit
    return this

  run: (memoryAdapter, callback) ->
    promise = new Promise bothback: callback
    matches = memoryAdapter.filter (doc, namespacePlusId) =>
      @testWithoutPaging doc, namespacePlusId

    matches = (deepCopy doc for doc in matches)

    if @_comparator
      matches.sort @_comparator

    {skip, limit, fields} = @_opts
    if limit isnt undefined
      skip = 0 if skip is undefined
      matches = matches.slice(skip, skip + limit)

    if selectType = @_selectType
      matches = for doc in matches
        projectedDoc = {}
        switch selectType
          when 'only'
            for field of fields
              assign projectedDoc, field, lookup(field, doc)
            assign projectedDoc, 'id', lookup('id', doc)
          when 'except'
            assignExcept projectedDoc, doc, fields

          else throw new Error
        projectedDoc

    promise.resolve null, matches
    return promise

assignExcept = (to, from, exceptions) ->
  return if from is undefined
  for key, val of from
    continue if key of exceptions

    nextExceptions = []
    hasNextExceptions = false
    for except of exceptions
      periodPos = except.indexOf '.'
      if except[0...periodPos] == key
        hasNextExceptions = true
        nextExceptions[excep[0..periodPos]] = 0

    if hasNextExceptions
      nextTo = to[key] = if Array.isArray from[key] then [] else {}
      assignExcept nextTo, from[key], nextExceptions
    else
      if Array.isArray from
        key = parseInt key, 10
      to[key] = from[key]
  return to
