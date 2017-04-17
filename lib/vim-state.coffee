{basename} = require 'path'

semver = require 'semver'
Delegato = require 'delegato'
jQuery = null

_ = require 'underscore-plus'
{Emitter, Disposable, CompositeDisposable, Range} = require 'atom'

settings = require './settings'
# HoverManager = require './hover-manager'
# SearchInput = require './search-input'
{getVisibleEditors, matchScopes, translatePointAndClip, haveSomeNonEmptySelection} = require './utils'
swrap = require './selection-wrapper'

# OperationStack = require './operation-stack'
LazyLoadedLibs = {}

# MarkManager = require './mark-manager'
# ModeManager = require './mode-manager'
# RegisterManager = require './register-manager'
# SearchHistoryManager = require './search-history-manager'
# CursorStyleManager = require './cursor-style-manager'
BlockwiseSelection = null
# OccurrenceManager = require './occurrence-manager'
# HighlightSearchManager = require './highlight-search-manager'
# MutationManager = require './mutation-manager'
# PersistentSelectionManager = require './persistent-selection-manager'
# FlashManager = require './flash-manager'

module.exports =
class VimState
  @vimStatesByEditor: new Map

  @getByEditor: (editor) -> @vimStatesByEditor.get(editor)
  @has: (editor) -> @vimStatesByEditor.has(editor)
  @delete: (editor) -> @vimStatesByEditor.delete(editor)
  @forEach: (fn) -> @vimStatesByEditor.forEach(fn)
  @clear: -> @vimStatesByEditor.clear()

  Delegato.includeInto(this)
  @delegatesProperty('mode', 'submode', toProperty: 'modeManager')
  @delegatesMethods('isMode', 'activate', toProperty: 'modeManager')
  @delegatesMethods('flash', 'flashScreenRange', toProperty: 'flashManager')
  @delegatesMethods('subscribe', 'getCount', 'setCount', 'hasCount', 'addToClassList', toProperty: 'operationStack')

  @defineLazyProperty: (name, fileToLoad) ->
    Object.defineProperty @prototype, name,
      get: ->
        propName = "__" + name
        this[propName] ?= do =>
          unless fileToLoad of LazyLoadedLibs
            unless atom.inSpecMode()
              console.log "# lazy-require: #{fileToLoad}, #{basename(@editor.getPath() ? '')}"
              # console.trace()
              # console.log '----------'
            LazyLoadedLibs[fileToLoad] = require(fileToLoad)
          klass = LazyLoadedLibs[fileToLoad]
          new klass(this)

  @lazyProperties =
    modeManager: './mode-manager'
    mark: './mark-manager'
    register: './register-manager'
    hover: './hover-manager'
    hoverSearchCounter: './hover-manager'
    searchHistory: './search-history-manager'
    highlightSearch: './highlight-search-manager'
    persistentSelection: './persistent-selection-manager'
    occurrenceManager: './occurrence-manager'
    mutationManager: './mutation-manager'
    flashManager: './flash-manager'
    searchInput: './search-input'
    operationStack: './operation-stack'
    cursorStyleManager: './cursor-style-manager'

  for propName, fileToLoad of @lazyProperties
    # console.log propName, fileToLoad
    @defineLazyProperty(propName, fileToLoad)

  constructor: (@editor, @statusBarManager, @globalState) ->
    @editorElement = @editor.element
    @emitter = new Emitter
    @subscriptions = new CompositeDisposable
    @previousSelection = {}
    @observeSelections()

    refreshHighlightSearch = =>
      @highlightSearch.refresh()
    @subscriptions.add @editor.onDidStopChanging(refreshHighlightSearch)

    @editorElement.classList.add('vim-mode-plus')
    if @getConfig('startInInsertMode') or matchScopes(@editorElement, @getConfig('startInInsertModeScopes'))
      @activate('insert')
    else
      @activate('normal')

    @editor.onDidDestroy(@destroy)
    @constructor.vimStatesByEditor.set(@editor, this)

  getConfig: (param) ->
    settings.get(param)

  # BlockwiseSelections
  # -------------------------
  getBlockwiseSelections: ->
    BlockwiseSelection ?= require './blockwise-selection'
    BlockwiseSelection.getSelections(@editor)

  getLastBlockwiseSelection: ->
    BlockwiseSelection ?= require './blockwise-selection'
    BlockwiseSelection.getLastSelection(@editor)

  getBlockwiseSelectionsOrderedByBufferPosition: ->
    BlockwiseSelection ?= require './blockwise-selection'
    BlockwiseSelection.getSelectionsOrderedByBufferPosition(@editor)

  clearBlockwiseSelections: ->
    BlockwiseSelection ?= require './blockwise-selection'
    BlockwiseSelection.clearSelections(@editor)

  # Other
  # -------------------------
  # FIXME: I want to remove this dengerious approach, but I couldn't find the better way.
  swapClassName: (classNames...) ->
    oldMode = @mode
    @editorElement.classList.remove('vim-mode-plus', oldMode + "-mode")
    @editorElement.classList.add(classNames...)

    new Disposable =>
      @editorElement.classList.remove(classNames...)
      classToAdd = ['vim-mode-plus', 'is-focused']
      if @mode is oldMode
        classToAdd.push(oldMode + "-mode")
      @editorElement.classList.add(classToAdd...)

  # All subscriptions here is celared on each operation finished.
  # -------------------------
  onDidChangeSearch: (fn) -> @subscribe @searchInput.onDidChange(fn)
  onDidConfirmSearch: (fn) -> @subscribe @searchInput.onDidConfirm(fn)
  onDidCancelSearch: (fn) -> @subscribe @searchInput.onDidCancel(fn)
  onDidCommandSearch: (fn) -> @subscribe @searchInput.onDidCommand(fn)

  # Select and text mutation(Change)
  onDidSetTarget: (fn) -> @subscribe @emitter.on('did-set-target', fn)
  emitDidSetTarget: (operator) -> @emitter.emit('did-set-target', operator)

  onWillSelectTarget: (fn) -> @subscribe @emitter.on('will-select-target', fn)
  emitWillSelectTarget: -> @emitter.emit('will-select-target')

  onDidSelectTarget: (fn) -> @subscribe @emitter.on('did-select-target', fn)
  emitDidSelectTarget: -> @emitter.emit('did-select-target')

  onDidFailSelectTarget: (fn) -> @subscribe @emitter.on('did-fail-select-target', fn)
  emitDidFailSelectTarget: -> @emitter.emit('did-fail-select-target')

  onWillFinishMutation: (fn) -> @subscribe @emitter.on('on-will-finish-mutation', fn)
  emitWillFinishMutation: -> @emitter.emit('on-will-finish-mutation')

  onDidFinishMutation: (fn) -> @subscribe @emitter.on('on-did-finish-mutation', fn)
  emitDidFinishMutation: -> @emitter.emit('on-did-finish-mutation')

  onDidSetOperatorModifier: (fn) -> @subscribe @emitter.on('did-set-operator-modifier', fn)
  emitDidSetOperatorModifier: (options) -> @emitter.emit('did-set-operator-modifier', options)

  onDidFinishOperation: (fn) -> @subscribe @emitter.on('did-finish-operation', fn)
  emitDidFinishOperation: -> @emitter.emit('did-finish-operation')

  onDidResetOperationStack: (fn) -> @subscribe @emitter.on('did-reset-operation-stack', fn)
  emitDidResetOperationStack: -> @emitter.emit('did-reset-operation-stack')

  # Select list view
  onDidConfirmSelectList: (fn) -> @subscribe @emitter.on('did-confirm-select-list', fn)
  onDidCancelSelectList: (fn) -> @subscribe @emitter.on('did-cancel-select-list', fn)

  # Proxying modeManger's event hook with short-life subscription.
  onWillActivateMode: (fn) -> @subscribe @modeManager.onWillActivateMode(fn)
  onDidActivateMode: (fn) -> @subscribe @modeManager.onDidActivateMode(fn)
  onWillDeactivateMode: (fn) -> @subscribe @modeManager.onWillDeactivateMode(fn)
  preemptWillDeactivateMode: (fn) -> @subscribe @modeManager.preemptWillDeactivateMode(fn)
  onDidDeactivateMode: (fn) -> @subscribe @modeManager.onDidDeactivateMode(fn)

  # Events
  # -------------------------
  onDidFailToPushToOperationStack: (fn) -> @emitter.on('did-fail-to-push-to-operation-stack', fn)
  emitDidFailToPushToOperationStack: -> @emitter.emit('did-fail-to-push-to-operation-stack')

  onDidDestroy: (fn) -> @emitter.on('did-destroy', fn)

  # * `fn` {Function} to be called when mark was set.
  #   * `name` Name of mark such as 'a'.
  #   * `bufferPosition`: bufferPosition where mark was set.
  #   * `editor`: editor where mark was set.
  # Returns a {Disposable} on which `.dispose()` can be called to unsubscribe.
  #
  #  Usage:
  #   onDidSetMark ({name, bufferPosition}) -> do something..
  onDidSetMark: (fn) -> @emitter.on('did-set-mark', fn)

  onDidSetInputChar: (fn) -> @emitter.on('did-set-input-char', fn)
  emitDidSetInputChar: (char) -> @emitter.emit('did-set-input-char', char)

  isAlive: ->
    @constructor.has(@editor)

  destroy: =>
    return unless @isAlive()
    @constructor.delete(@editor)

    BlockwiseSelection ?= require './blockwise-selection'
    BlockwiseSelection.clearSelections(@editor)

    @subscriptions.dispose()

    if @editor.isAlive()
      @resetNormalMode()
      @reset()
      @editorElement.component?.setInputEnabled(true)
      @editorElement.classList.remove('vim-mode-plus', 'normal-mode')

    {
      @hover, @hoverSearchCounter, @operationStack,
      @searchHistory, @cursorStyleManager
      @modeManager, @register
      @editor, @editorElement, @subscriptions,
      @occurrenceManager
      @previousSelection
      @persistentSelection
    } = {}
    @emitter.emit 'did-destroy'

  checkSelection: (event) ->
    return unless atom.workspace.getActiveTextEditor() is @editor
    return if @operationStack.isProcessing()
    return if @mode is 'insert'
    # Intentionally using target.closest('atom-text-editor')
    # Don't use target.getModel() which is work for CustomEvent but not work for mouse event.
    return unless @editorElement is event.target?.closest?('atom-text-editor')
    return if event.type.startsWith('vim-mode-plus') # to match vim-mode-plus: and vim-mode-plus-user:

    if haveSomeNonEmptySelection(@editor)
      @editorElement.component.updateSync()
      wise = swrap.detectWise(@editor)
      if @isMode('visual', wise)
        for $selection in swrap.getSelections(@editor)
          $selection.saveProperties()
        @updateCursorsVisibility()
      else
        @activate('visual', wise)
    else
      @activate('normal') if @mode is 'visual'

  observeSelections: ->
    checkSelection = @checkSelection.bind(this)
    @editorElement.addEventListener('mouseup', checkSelection)
    @subscriptions.add new Disposable =>
      @editorElement.removeEventListener('mouseup', checkSelection)

    @subscriptions.add atom.commands.onDidDispatch(checkSelection)

    @editorElement.addEventListener('focus', checkSelection)
    @subscriptions.add new Disposable =>
      @editorElement.removeEventListener('focus', checkSelection)

  # What's this?
  # editor.clearSelections() doesn't respect lastCursor positoin.
  # This method works in same way as editor.clearSelections() but respect last cursor position.
  clearSelections: ->
    @editor.setCursorBufferPosition(@editor.getCursorBufferPosition())

  resetNormalMode: ({userInvocation}={}) ->
    BlockwiseSelection ?= require './blockwise-selection'
    BlockwiseSelection.clearSelections(@editor)

    if userInvocation ? false
      switch
        when @editor.hasMultipleCursors()
          @clearSelections()
        when @hasPersistentSelections() and @getConfig('clearPersistentSelectionOnResetNormalMode')
          @clearPersistentSelections()
        when @occurrenceManager.hasPatterns()
          @occurrenceManager.resetPatterns()

      if @getConfig('clearHighlightSearchOnResetNormalMode')
        @globalState.set('highlightSearchPattern', null)
    else
      @clearSelections()
    @activate('normal')

  init: ->
    @saveOriginalCursorPosition()

  reset: ->
    @register.reset() if @__register?
    @searchHistory.reset() if @__searchHistory?
    @hover.reset() if @__hover?
    @operationStack.reset() if @__operationStack?
    @mutationManager.reset() if @__mutationManager?

  isVisible: ->
    @editor in getVisibleEditors()

  updateCursorsVisibility: ->
    @cursorStyleManager.refresh()

  # FIXME: naming, updateLastSelectedInfo ?
  updatePreviousSelection: ->
    if @isMode('visual', 'blockwise')
      properties = @getLastBlockwiseSelection()?.getProperties()
    else
      properties = swrap(@editor.getLastSelection()).getProperties()

    # TODO#704 when cursor is added in visual-mode, corresponding selection prop yet not exists.
    return unless properties

    {head, tail} = properties

    if head.isGreaterThanOrEqual(tail)
      [start, end] = [tail, head]
      head = end = translatePointAndClip(@editor, end, 'forward')
    else
      [start, end] = [head, tail]
      tail = end = translatePointAndClip(@editor, end, 'forward')

    @mark.set('<', start)
    @mark.set('>', end)
    @previousSelection = {properties: {head, tail}, @submode}

  # Persistent selection
  # -------------------------
  hasPersistentSelections: ->
    @persistentSelection.hasMarkers()

  getPersistentSelectionBufferRanges: ->
    @persistentSelection.getMarkerBufferRanges()

  clearPersistentSelections: ->
    @persistentSelection.clearMarkers()

  # Animation management
  # -------------------------
  scrollAnimationEffect: null
  requestScrollAnimation: (from, to, options) ->
    jQuery ?= require('atom-space-pen-views').jQuery
    @scrollAnimationEffect = jQuery(from).animate(to, options)

  finishScrollAnimation: ->
    @scrollAnimationEffect?.finish()
    @scrollAnimationEffect = null

  # Other
  # -------------------------
  saveOriginalCursorPosition: ->
    @originalCursorPosition = null
    @originalCursorPositionByMarker?.destroy()

    if @mode is 'visual'
      selection = @editor.getLastSelection()
      point = swrap(selection).getBufferPositionFor('head', from: ['property', 'selection'])
    else
      point = @editor.getCursorBufferPosition()
    @originalCursorPosition = point
    @originalCursorPositionByMarker = @editor.markBufferPosition(point, invalidate: 'never')

  restoreOriginalCursorPosition: ->
    @editor.setCursorBufferPosition(@getOriginalCursorPosition())

  getOriginalCursorPosition: ->
    @originalCursorPosition

  getOriginalCursorPositionByMarker: ->
    @originalCursorPositionByMarker.getStartBufferPosition()
