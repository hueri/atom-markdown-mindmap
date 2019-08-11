path = require 'path'

{Emitter, Disposable, CompositeDisposable} = require 'atom'
{$, $$$, ScrollView} = require 'atom-space-pen-views'
Grim = require 'grim'
_ = require 'underscore-plus'
fs = require 'fs-plus'
{File} = require 'atom'
markmapParse = require 'markmap/lib/parse.markdown'
markmapMindmap = require 'markmap/lib/view.mindmap'
transformHeadings = require 'markmap/lib/transform.headings'
d3 = require 'd3'
require 'markmap/lib/d3-flextree'

SVG_PADDING = 15
SCHEME_REGEX = /[a-zA-Z][-+.a-zA-Z0-9]*:\/\//

getSVG = ({ body, width, height, viewbox }) ->
  """<?xml version="1.0" standalone="no"?>
  <!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN"
    "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">
  <svg xmlns="http://www.w3.org/2000/svg" version="1.1"
       width="#{width}" height="#{height}" viewBox="#{viewbox}">
    <defs>
      <style type="text/css"><![CDATA[
        .markmap-node {
          cursor: pointer;
        }

        .markmap-node-circle {
          fill: #fff;
          stroke-width: 1.5px;
        }

        .markmap-node-text {
          fill:  #000;
          font: 10px sans-serif;
        }

        .markmap-link {
          fill: none;
        }
      ]]></style>
    </defs>
    #{body}
  </svg>
  """

transformLinks = (headings, filepath) ->
  dir = path.dirname(Script(filepath))
  result = []
  headings.forEach (h) ->
    h.filepath = filepath
    if h.href
      if h.href.match SCHEME_REGEX
        return
      if not h.name
        h.name = path.basename h.href
      if h.href[0] != "/"
        h.href = path.resolve dir, h.href
    result.push h
  result

module.exports =
class MarkdownMindmapView extends ScrollView
  @content: ->
    @div class: 'markdown-mindmap native-key-bindings', tabindex: -1

  constructor: ({@editorId, @filePath}) ->
    super
    @emitter = new Emitter
    @disposables = new CompositeDisposable
    @watchers = new CompositeDisposable
    @loaded = false

  attached: ->
    return if @isAttached
    @isAttached = true

    if @editorId?
      @resolveEditor(@editorId)
    else
      if atom.workspace?
        @subscribeToFilePath(@filePath)
      else
        @disposables.add atom.packages.onDidActivateInitialPackages =>
          @subscribeToFilePath(@filePath)

  serialize: ->
    deserializer: 'MarkdownMindmapView'
    filePath: @getPath()
    editorId: @editorId

  destroy: ->
    @disposables.dispose()
    @watchers.dispose()

  onDidChangeTitle: (callback) ->
    @emitter.on 'did-change-title', callback

  onDidChangeModified: (callback) ->
    # No op to suppress deprecation warning
    new Disposable

  onDidChangeMarkdown: (callback) ->
    @emitter.on 'did-change-markdown', callback

  subscribeToFilePath: (filePath) ->
    @file = new File(filePath)
    @emitter.emit 'did-change-title'
    @handleEvents()
    @renderMarkdown()

  resolveEditor: (editorId) ->
    resolve = =>
      @editor = @editorForId(editorId)

      if @editor?
        @emitter.emit 'did-change-title' if @editor?
        @handleEvents()
        @renderMarkdown()
      else
        # The editor this preview was created for has been closed so close
        # this preview since a preview cannot be rendered without an editor
        atom.workspace?.paneForItem(this)?.destroyItem(this)

    if atom.workspace?
      resolve()
    else
      @disposables.add atom.packages.onDidActivateInitialPackages(resolve)

  editorForId: (editorId) ->
    for editor in atom.workspace.getTextEditors()
      return editor if editor.id?.toString() is editorId.toString()
    null

  handleEvents: ->
    @disposables.add atom.grammars.onDidAddGrammar => _.debounce((=> @renderMarkdown()), 250)
    @disposables.add atom.grammars.onDidUpdateGrammar _.debounce((=> @renderMarkdown()), 250)

    # disable events for now, maybe reimplement them later
    atom.commands.add @element,
      # 'core:move-up': =>
      #   @scrollUp()
      # 'core:move-down': =>
      #   @scrollDown()
      'core:copy': (event) =>
        event.stopPropagation() if @copyToClipboard()
      # 'markdown-mindmap:zoom-in': =>
      #   zoomLevel = parseFloat(@css('zoom')) or 1
      #   @css('zoom', zoomLevel + .1)
      # 'markdown-mindmap:zoom-out': =>
      #   zoomLevel = parseFloat(@css('zoom')) or 1
      #   @css('zoom', zoomLevel - .1)
      # 'markdown-mindmap:reset-zoom': =>
      #   @css('zoom', 1)

    changeHandler = =>
      @renderMarkdown()

      # TODO: Remove paneForURI call when ::paneForItem is released
      pane = atom.workspace.paneForItem?(this) ? atom.workspace.paneForURI(@getURI())
      if pane? and pane isnt atom.workspace.getActivePane()
        pane.activateItem(this)

    if @file?
      @disposables.add @file.onDidChange(changeHandler)
    else if @editor?
      @disposables.add @editor.getBuffer().onDidStopChanging ->
        changeHandler() if atom.config.get 'markdown-mindmap.liveUpdate'
      @disposables.add @editor.onDidChangePath => @emitter.emit 'did-change-title'
      @disposables.add @editor.getBuffer().onDidSave ->
        changeHandler() unless atom.config.get 'markdown-mindmap.liveUpdate'
      @disposables.add @editor.getBuffer().onDidReload ->
        changeHandler() unless atom.config.get 'markdown-mindmap.liveUpdate'

    @disposables.add atom.config.observe 'markdown-mindmap.theme', changeHandler

    @disposables.add atom.config.observe 'markdown-mindmap.linkShape', changeHandler

    @disposables.add atom.config.observe 'markdown-mindmap.parseListItems', changeHandler

    @disposables.add atom.config.observe 'markdown-mindmap.parseNestedLinks', changeHandler

    @disposables.add atom.config.observe 'markdown-mindmap.truncateLabels', changeHandler

  renderMarkdown: ->
    @showLoading() unless @loaded
    @getMarkdownSource().then ([source, filepath]) => @renderMarkdownText(source, filepath) if source?

  getMarkdownSource: ->
    filepath = @getPath()
    if @file?
      @file.read().then (source) -> [source, filepath]
    else if @editor?
      Promise.resolve([@editor.getText(), filepath])
    else
      Promise.resolve(null)

  getSVG: (callback) ->
    state = @mindmap.state
    nodes = @mindmap.layout(state).nodes
    minX = Math.round(d3.min(nodes, (d) -> d.x))
    minY = Math.round(d3.min(nodes, (d) -> d.y))
    maxX = Math.round(d3.max(nodes, (d) -> d.x))
    maxY = Math.round(d3.max(nodes, (d) -> d.y + d.y_size))
    realHeight = maxX - minX
    realWidth = maxY - minY
    heightOffset = state.nodeHeight

    minX -= SVG_PADDING;
    minY -= SVG_PADDING;
    realHeight += 2*SVG_PADDING;
    realWidth += 2*SVG_PADDING;

    node = @mindmap.svg.node()

    # unset transformation before we take the svg, we will handle it via viewport setting
    transform = node.getAttribute('transform')
    node.removeAttribute('transform')

    # take the svg
    body = @mindmap.svg.node().parentNode.innerHTML

    # restore the transformation
    node.setAttribute('transform', transform)

    callback(null, getSVG({
      body,
      width: realWidth + 'px',
      height: realHeight + 'px',
      viewbox: "#{minY} #{minX - heightOffset} #{realWidth} #{realHeight + heightOffset}"
    }))

  createNodeWatcher: (node) ->
    atom.workspace.openTextFile(node.href)
    .then (editor) =>
        buffer = editor.getBuffer()
        # TODO likely to need to destroy buffer later
        buffer.retain()
        editor.destroy()
        buffer.onDidChange () =>
          @updateSubtree(node, buffer.getText())
    .catch =>
        f = new File(node.path)
        f.onDidChange () =>
          f.read().then (text) =>
            @updateSubtree(node, text)

  updateSubtree: (node, text) ->
    if node.children
      data = @parseMarkdown(text, node.href)
      @mindmap.preprocessData(data, node)
      node.children = data.children
      duration = @mindmap.state.duration
      @mindmap.set({duration: 0}).update().set({duration})
      @hookEvents()

  loadTextContent: (uri) ->
    atom.workspace.openTextFile(uri)
    .then (editor) =>
      text = editor.getBuffer().getText()
      editor.destroy()
      text
    .catch =>
      new File(uri).read()

  hookEvents: () ->
    nodes = @mindmap.svg.selectAll('g.markmap-node')
    toggleHandler = () =>
      node = arguments[0]
      if node.href and not node.children
        @loadTextContent(node.href).then (text) =>
          delete node._children
          data = @parseMarkdown(text, node.href)
          if (data.children.length > 0)
            @mindmap.preprocessData(data, node)
            node.children = data.children
            @mindmap.update node
            @hookEvents()
          else
            @scrollToLine(node.href, 0)
        @createNodeWatcher(node).then (subscription) =>
          @watchers.add subscription
      else
        @mindmap.click.apply(@mindmap, arguments)
        @hookEvents()
    nodes.on('click', null)
    nodes.selectAll('circle').on('click', toggleHandler)
    nodes.selectAll('text,rect').on 'click', (d) =>
      @scrollToLine(d.filepath || @getPath(), d.line)

  parseMarkdown: (text, filepath) ->
    data = markmapParse(text, {
      lists: atom.config.get('markdown-mindmap.parseListItems')
      links: atom.config.get('markdown-mindmap.parseNestedLinks')
    })
    transformHeadings(transformLinks(data, filepath))

  renderMarkdownText: (text, filepath) ->
      # if error
      #   @showError(error)
      # else

      # TODO paralel rendering
      data = @parseMarkdown(text, filepath)

      watchers = new CompositeDisposable
      promises = []
      files = {}

      # Collect expanded sub trees
      if @mindmap?.state.root
        traverse = (node) ->
          if node.href and (node.children or node._children)
            files[node.href] = true
          if node.children
            node.children.forEach(traverse)
        traverse(@mindmap.state.root)

      # Load content for collected sub trees into the new tree
      traverse = (node) =>
        if node.href and files[node.href]
          promises.push @loadTextContent(node.href).then (text) =>
            childData = @parseMarkdown(text, node.href)
            @mindmap.preprocessData(childData, node)
            node.children = childData.children
          @createNodeWatcher(node).then (subscription) =>
            watchers.add subscription
        if node.children
          node.children.forEach(traverse)
      traverse(data)

      @watchers.dispose()
      @watchers = watchers

      Promise.all(promises).then =>
        @hideLoading()
        @loaded = true

        options =
          preset: atom.config.get('markdown-mindmap.theme').replace(/-dark$/, '')
          linkShape: atom.config.get('markdown-mindmap.linkShape')
          truncateLabels: atom.config.get('markdown-mindmap.truncateLabels')
          duration: 400
        if not @mindmap?
          @mindmap = markmapMindmap($('<svg style="height: 100%; width: 100%"></svg>').appendTo(this).get(0), data, options)
        else
          @mindmap.setData(data).set(options).set({duration: 0}).update().set({duration: options.duration})

        cls = this.attr('class').replace(/markdown-mindmap-theme-[^\s]+/, '')
        cls += ' markdown-mindmap-theme-' + atom.config.get('markdown-mindmap.theme')
        this.attr('class', cls)

        @hookEvents()

        @emitter.emit 'did-change-markdown'
        @originalTrigger('markdown-mindmap:markdown-changed')

  scrollToLine: (filepath, line) ->
    atom.workspace.open(filepath,
      initialLine: line
      activatePane: true
      searchAllPanes: true).then (editor) ->
        cursor = editor.getCursorScreenPosition()
        view = atom.views.getView(editor)
        pixel = view.pixelPositionForScreenPosition(cursor).top
        editor.getElement().setScrollTop pixel

        # A trick to allow preview plugins like markdown-preview-enhanced to sync scroll position
        setTimeout ->
          editor.setCursorBufferPosition([line, Infinity])
        , 0

  getTitle: ->
    if @file?
      "#{path.basename(@getPath())} Mindmap"
    else if @editor?
      "#{@editor.getTitle()} Mindmap"
    else
      "Markdown Mindmap"

  getIconName: ->
    "markdown"

  getURI: ->
    if @file?
      "markdown-mindmap://#{@getPath()}"
    else
      "markdown-mindmap://editor/#{@editorId}"

  getPath: ->
    if @file?
      @file.getPath()
    else if @editor?
      @editor.getPath()

  getGrammar: ->
    @editor?.getGrammar()

  getDocumentStyleSheets: -> # This function exists so we can stub it
    document.styleSheets

  getTextEditorStyles: ->

    textEditorStyles = document.createElement("atom-styles")
    textEditorStyles.setAttribute "context", "atom-text-editor"
    document.body.appendChild textEditorStyles

    # Force styles injection
    textEditorStyles.initialize()

    # Extract style elements content
    Array.prototype.slice.apply(textEditorStyles.childNodes).map (styleElement) ->
      styleElement.innerText

  getMarkdownMindmapCSS: ->
    markdowPreviewRules = []
    ruleRegExp = /\.markdown-mindmap/
    cssUrlRefExp = /url\(atom:\/\/markdown-mindmap\/assets\/(.*)\)/

    for stylesheet in @getDocumentStyleSheets()
      if stylesheet.rules?
        for rule in stylesheet.rules
          # We only need `.markdown-review` css
          markdowPreviewRules.push(rule.cssText) if rule.selectorText?.match(ruleRegExp)?

    markdowPreviewRules
      .concat(@getTextEditorStyles())
      .join('\n')
      .replace(/atom-text-editor/g, 'pre.editor-colors')
      .replace(/:host/g, '.host') # Remove shadow-dom :host selector causing problem on FF
      .replace cssUrlRefExp, (match, assetsName, offset, string) -> # base64 encode assets
        assetPath = path.join __dirname, '../assets', assetsName
        originalData = fs.readFileSync assetPath, 'binary'
        base64Data = new Buffer(originalData, 'binary').toString('base64')
        "url('data:image/jpeg;base64,#{base64Data}')"

  showError: (result) ->
    failureMessage = result?.message

    @html $$$ ->
      @h2 'Previewing Markdown Failed'
      @h3 failureMessage if failureMessage?

  showLoading: ->
    @loading = true
    spinner = @find('>.markdown-spinner')
    if spinner.length == 0
      @append $$$ ->
        @div class: 'markdown-spinner', 'Loading Markdown\u2026'
    spinner.show()

  hideLoading: ->
    @loading = false
    @find('>.markdown-spinner').hide()

  copyToClipboard: ->
    return false if @loading

    @getSVG (error, html) ->
      if error?
        console.warn('Copying Markdown as SVG failed', error)
      else
        atom.clipboard.write(html)

    true

  getSaveDialogOptions: ->
    defaultPath = @getPath()
    if defaultPath
      defaultPath += '.svg'
    else
      defaultPath = 'untitled.md.svg'
      if projectPath = atom.project.getPaths()[0]
        defaultPath = path.join(projectPath, defaultPath)

    return {defaultPath}

  saveAs: (htmlFilePath) ->
    if @loading
      atom.notifications.addWarning('Please wait until the Mindmap Preview has finished loading before saving')
      return

    @getSVG (error, htmlBody) =>
      if error?
        console.warn('Saving Markdown as SVG failed', error)
      else
        fs.writeFileSync(htmlFilePath, htmlBody)

  isEqual: (other) ->
    @[0] is other?[0] # Compare DOM elements

if Grim.includeDeprecatedAPIs
  MarkdownMindmapView::on = (eventName) ->
    if eventName is 'markdown-mindmap:markdown-changed'
      Grim.deprecate("Use MarkdownMindmapView::onDidChangeMarkdown instead of the 'markdown-mindmap:markdown-changed' jQuery event")
    super
