# We override the original lookup method with a similar one, which supports components as well.
#
# Now the order of the lookup will be, in order:
#   a helper of the current template
#   a property of the current component
#   the name of a component
#   the name of a template
#   global helper
#   a property of the data context
#
# Returns a function, a non-function value, or null. If a function is found, it is bound appropriately.
#
# NOTE: This function must not establish any reactive dependencies itself.  If there is any reactivity
# in the value, lookup should return a function.
#
# TODO: Should we also lookup for a property of the component-level data context (and template-level data context)?

Blaze._getTemplateHelper = (template, name, templateInstance) ->
  isKnownOldStyleHelper = false
  if template.__helpers.has name
    helper = template.__helpers.get name
    if helper is Blaze._OLDSTYLE_HELPER
      isKnownOldStyleHelper = true
    else
      return helper

  # Old-style helper.
  if name of template
    # Only warn once per helper.
    unless isKnownOldStyleHelper
      template.__helpers.set name, Blaze._OLDSTYLE_HELPER
      unless template._NOWARN_OLDSTYLE_HELPERS
        Blaze._warn "Assigning helper with `" + template.viewName + "." + name + " = ...` is deprecated.  Use `" + template.viewName + ".helpers(...)` instead."
    return template[name]

  # TODO: Can we simply ignore reactivity here? Can this template instance or parent template instances change without reconstructing the component as well? I don't think so. Only data context is changing and this is why templateInstance or .get() are reactive and we do not care about data context here.
  component = Tracker.nonreactive ->
    templateInstance = templateInstance()
    templateInstance.get 'component'

  # Component.
  if component and name of component
    return _.bind component[name], component

  null

viewToTemplateInstance = (view) ->
  # We skip contentBlock views which are injected by Meteor when using
  # block helpers (in addition to block helper view). This matches more
  # the visual structure of templates and not the internal implementation.
  while view and (not view.template or view.name is '(contentBlock)')
    view = view.originalParentView or view.parentView

  # Body view has template field, but not templateInstance. We return null in that case.
  return null unless view?.templateInstance

  _.bind view.templateInstance, view

addEvents = (view, component) ->
  for events in component.events()
    eventMap = {}

    for spec, handler of events
      do (spec, handler) ->
        eventMap[spec] = (args...) ->
          event = args[0]

          currentView = Blaze.getView event.currentTarget
          templateInstance = viewToTemplateInstance currentView

          # We set template instance based on the current target so that inside event handlers
          # BlazeComponent.currentComponent() returns the component of event target.
          Template._withTemplateInstanceFunc templateInstance, ->
            # We set view based on the current target so that inside event handlers
            # BlazeComponent.currentData() (and Blaze.getData() and Template.currentData())
            # returns data context of event target and not component/template.
            Blaze._withCurrentView currentView, ->
              handler.apply component, args

          # Make sure CoffeeScript does not return anything. Returning from event
          # handlers is deprecated.
          return

    Blaze._addEventMap view, eventMap

  return

Blaze._getComponent = (componentName) ->
  BlazeComponent.getComponentTemplate componentName

createUIHooks = (component, parentNode) ->
  insertElement: (node, before) =>
    node._uihooks ?= createUIHooks component, node
    component.insertDOMElement parentNode, node, before

  moveElement: (node, before) =>
    node._uihooks ?= createUIHooks component, node
    component.moveDOMElement parentNode, node, before

  removeElement: (node) =>
    node._uihooks ?= createUIHooks component, node
    component.removeDOMElement node

originalDOMRangeAttach = Blaze._DOMRange::attach
Blaze._DOMRange::attach = (parentElement, nextNode, _isMove, _isReplace) ->
  if component = @view._templateInstance?.component
    oldUIHooks = parentElement._uihooks
    try
      parentElement._uihooks = createUIHooks component, parentElement
      return originalDOMRangeAttach.apply @, arguments
    finally
      parentElement._uihooks = oldUIHooks if oldUIHooks

  originalDOMRangeAttach.apply @, arguments

class BlazeComponent
  @components: {}

  @register: (componentName, componentClass) ->
    throw new Error "Component name is required for registration." unless componentName

    # To allow calling @register 'name' from inside a class body.
    componentClass ?= @

    throw new Error "Component '#{ componentName }' already registered." if componentName of @components

    # The last condition is to make sure we do not throw the exception when registering a subclass.
    # Subclassed components have at this stage the same component as the parent component, so we have
    # to check if they are the same class. If not, this is not an error, it is a subclass.
    if componentClass.componentName() and componentClass.componentName() isnt componentName and @components[componentClass.componentName()] is componentClass
      throw new Error "Component '#{ componentName }' already registered under the name '#{ componentClass.componentName() }'."

    componentClass.componentName componentName
    assert componentClass.componentName() is componentName

    @components[componentName] = componentClass

  @getComponent: (componentName) ->
    @components[componentName] or null

  @getComponentTemplate: (componentClass) ->
    # To allow calling component.getComponentTemplate() on an unregistered component.
    componentClass ?= @

    if _.isString componentClass
      return null unless componentClass of @components

      componentClass = @components[componentClass]

    componentClassTemplate = componentClass.template()
    if _.isString componentClassTemplate
      templateBase = Template[componentClassTemplate]
      throw new Error "Template '#{ componentClassTemplate }' cannot be found." unless templateBase
    else
      templateBase = componentClassTemplate
      assert templateBase

    # Create a new component template based on the Blaze template. We want our own template
    # because the same Blaze template could be reused between multiple components.
    # TODO: Should we cache these templates based on (componentName, templateBase) pair? We could use tow levels of ES6 Maps, componentName -> templateBase -> template.
    template = new Blaze.Template "BlazeComponent.#{ componentClass.componentName() or 'unnamed' }", templateBase.renderFunction

    # We on purpose do not reuse helpers, events, and hooks. Templates are used only for HTML rendering.

    template.onCreated ->
      @view._onViewRendered =>
        # Attach events the first time template instance renders.
        addEvents @view, @component if @view.renderCount is 1

      # @ is a template instance.
      @component = new componentClass()
      @component.templateInstance = @
      @component.onCreated()

    template.onRendered ->
      # @ is a template instance.
      @component.onRendered()

    template.onDestroyed ->
      # @ is a template instance.
      @component.onDestroyed()

    template

  @template: ->
    # You have to override this method with a method which returns a template name or template itself.
    throw new Error "Component class method 'template' not overridden."

  # Component name is set in the BlazeComponent.register. If not using a registered component and a component name is
  # wanted, component name has to be set manually or this class method should be overridden with a custom implementation.
  # Care should be taken that unregistered components have their own name and not the name of their parent class, which
  # they would have by default. Probably component name should be set in the constructor for such classes, or by calling
  # componentName class method manually on the new class of this new component.
  @componentName: (componentName) ->
    # Setter.
    @_componentName = componentName if componentName

    # Getter.
    @_componentName or null

  # We allow access to the component name through a method so that it can be accessed in templates in an easy way.
  componentName: ->
    @constructor.componentName()

  onCreated: ->

  onRendered: ->

  onDestroyed: ->

  insertDOMElement: (parent, node, before) ->
    parent.insertBefore node, before

  moveDOMElement: (parent, node, before) ->
    parent.insertBefore node, before

  removeDOMElement: (node) ->
    node.parentNode.removeChild node

  events: ->
    []

  # Component-level data context. Reactive. Use this to always get the
  # top-level data context used to render the component.
  data: ->
    Blaze.getData(@templateInstance.view) or null

  # Caller-level data context. Reactive. Use this to get in event handlers the data
  # context at the place where event originated (target context). In template helpers
  # the data context where template helpers were called. In onCreated, onRendered,
  # or onDestroyed, the same as @data(). Inside a template this is the same as this.
  currentData: ->
    Blaze.getData() or null

  # Caller-level component. Reactive. In most cases the same as @, but in event handlers
  # it returns the component at the place where event originated (target component).
  currentComponent: ->
    Template.instance()?.get('component') or null

# We copy utility methods ($, findAll, autorun, subscribe, etc.) from the template instance prototype.
for methodName, method of Blaze.TemplateInstance::
  BlazeComponent::[methodName] = (args...) ->
    @templateInstance[methodName] args...
