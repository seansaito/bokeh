_ = require "underscore"
kiwi = require "kiwi"
{Variable} = kiwi
p = require "../core/properties"
BokehView = require "../core/bokeh_view"
Model = require "../model"
{ mixin_layoutable, EQ } = require "./layoutable"

class BoxView extends BokehView
  className: "bk-box"

  initialize: (options) ->
    super(options)
    @_created_child_views = false
    @listenTo(@model, 'change', @render)

  render: () ->
    # obviously this is too simple for real life, where
    # we have to see if the children list has changed
    if not @_created_child_views
      children = @model.get_layoutable_children()
      for child in children
        view = new child.default_view({ model: child })
        view.render()
        @$el.append(view.$el)
      @_created_child_views = true

    @$el.css({
      position: 'absolute',
      left: @mget('dom_left'),
      top: @mget('dom_top'),
      width: @model._width._value,
      height: @model._height._value
    });

class Box extends Model
  default_view: BoxView

  constructor: (attrs, options) ->
    super(attrs, options)
    @set('dom_left', 0)
    @set('dom_top', 0)
    @_width = new Variable()
    @_height = new Variable()
    # for children that want to be the same size
    # as other children, make them all equal to these
    @_child_equal_size_width = new Variable()
    @_child_equal_size_height = new Variable()

    # these are passed up to our parent after basing
    # them on the child box-equal-size vars
    @_box_equal_size_top = new Variable()
    @_box_equal_size_bottom = new Variable()
    @_box_equal_size_left = new Variable()
    @_box_equal_size_right = new Variable()

  props: ->
    return _.extend {}, super(), {
      children: [ p.Array, [] ],
      spacing:  [ p.Number, 6 ]
    }

  _ensure_origin_variables: (child) ->
    if '__Box_x' not of child
      child['__Box_x'] = new Variable('child_origin_x')
    if '__Box_y' not of child
      child['__Box_y'] = new Variable('child_origin_y')
    return [child['__Box_x'], child['__Box_y']]

  get_constraints: () ->
    children = @get_layoutable_children()
    if children.length == 0
      []
    else
      child_rect = (child) =>
        vars = child.get_constrained_variables()
        width = vars['width']
        height = vars['height']
        [x, y] = @_ensure_origin_variables(child)
        [x, y, width, height]

      # return [coordinate, size] pair in box-aligned direction
      span = (rect) =>
        if @_horizontal
          [rect[0], rect[2]]
        else
          [rect[1], rect[3]]

      add_equal_size_constraints = (child, constraints) =>
        # child's "interesting area" (like the plot area) is the
        # same size as the previous child (a child can opt out of
        # this by not returning the box-equal-size variables)

        vars = child.get_constrained_variables()
        if 'box-equal-size-top' of vars
          constraints.push(EQ([-1, vars['box-equal-size-top']], [-1, vars['box-equal-size-bottom']], vars['height'], @_child_equal_size_height))

        if 'box-equal-size-left' of vars
          constraints.push(EQ([-1, vars['box-equal-size-left']], [-1, vars['box-equal-size-right']], vars['width'], @_child_equal_size_width))

      info = (child) =>
        {
          span: span(child_rect(child))
          # well, we used to have more in here...
        }

      result = []

      spacing = @get('spacing')

      for child in children
        # make total widget sizes fill the orthogonal direction
        rect = child_rect(child)
        if @_horizontal
          result.push(EQ(rect[3], [ -1, @_height ]))
        else
          result.push(EQ(rect[2], [ -1, @_width ]))

        add_equal_size_constraints(child, result)

        # pull child constraints up recursively
        result = result.concat(child.get_constraints())

      last = info(children[0])
      result.push(EQ(last.span[0], 0))
      for i in [1...children.length]
        next = info(children[i])
        # each child's start equals the previous child's end
        # (with spacing inserted)
        result.push(EQ(last.span[0], last.span[1], spacing, [-1, next.span[0]]))

        last = next

      # last child's right side has to stick to the right side of the box
      if @_horizontal
        total = @_width
      else
        total = @_height
      result.push(EQ(last.span[0], last.span[1], [-1, total]))

      # align outermost edges in both dimensions
      result = result.concat(@_align_outer_edges_constraints(true)) # horizontal=true
      result = result.concat(@_align_outer_edges_constraints(false))

      # line up edges in same-arity boxes
      result = result.concat(@_align_inner_cell_edges_constraints())

      # build our equal-size bounds from the child ones
      result = result.concat(@_box_equal_size_bounds(true)) # horizontal=true
      result = result.concat(@_box_equal_size_bounds(false))

    result

  get_constrained_variables: () ->
    {
      'width' : @_width
      'height' : @_height
      'box-equal-size-top' : @_box_equal_size_top
      'box-equal-size-bottom' : @_box_equal_size_bottom
      'box-equal-size-left' : @_box_equal_size_left
      'box-equal-size-right' : @_box_equal_size_right
    }

  get_layoutable_children: () ->
    @get('children')

  @_left_right_inner_cell_edge_variables = [
    'on-left-cell-align',
    'on-right-cell-align'
  ]

  @_top_bottom_inner_cell_edge_variables = [
    'on-top-cell-align',
    'on-bottom-cell-align'
  ]

  _flatten_cell_edge_variables: (add_path) ->
    # we build a flat dictionary of variables keyed by strings like these:
    # "on-top-cell-align"
    # "on-top-cell-align row-2-0-"
    # "on-top-cell-align row-1-0-row-2-0-"
    #
    # the trailing stuff is the "path" to the box cell through all
    # ancestor cells.

    if @_horizontal
      # if we're a row, pull vertical guides out of our children
      # so we can match them up with other rows
      relevant_edges = Box._left_right_inner_cell_edge_variables
    else
      relevant_edges = Box._top_bottom_inner_cell_edge_variables

    children = @get_layoutable_children()
    arity = children.length
    flattened = {}
    cell = 0
    for child in children
      if child instanceof Box
        cell_vars = child._flatten_cell_edge_variables(true)
      else
        cell_vars = {}
        all_vars = child.get_constrained_variables()
        for name in relevant_edges
          if name of all_vars
            cell_vars[name] = [all_vars[name]]

      for key, variables of cell_vars
        if add_path
          parsed = key.split(" ")
          kind = parsed[0]
          if parsed.length > 1
            path = parsed[1]
          else
            path = ""
          if @_horizontal
            direction = "row"
          else
            direction = "col"
          # TODO should we "ignore" arity-1 boxes potentially by not adding a path suffix?
          new_key = "#{kind} #{direction}-#{arity}-#{cell}-#{path}"
        else
          new_key = key
        if new_key of flattened
          flattened[new_key] = flattened[new_key].concat(variables)
        else
          flattened[new_key] = variables

      cell = cell + 1
    return flattened

  _align_inner_cell_edges_constraints: () ->
    flattened = @_flatten_cell_edge_variables(false)

    result = []
    for key, variables of flattened
      if variables.length > 1
        #console.log("constraining ", key, " ", variables)
        last = variables[0]
        for i in [1...variables.length]
          result.push(EQ(variables[i], [-1, last]))

    result

  # returns a two-item array where each item is a list of edge
  # children from the start and end respectively
  _find_edge_leaves: (horizontal) ->
    children = @get_layoutable_children()

    # console.log("  finding edge leaves in #{children.length}-#{@type}, " +
    #  "our orientation #{@_horizontal} finding #{horizontal} children ", children)

    leaves = [ [] , [] ]
    if children.length > 0
      if @_horizontal == horizontal
        # note start and end may be the same
        start = children[0]
        end = children[children.length - 1]

        if start instanceof Box
          leaves[0] = leaves[0].concat(start._find_edge_leaves(horizontal)[0])
        else
          leaves[0].push(start)

        if end instanceof Box
          leaves[1] = leaves[1].concat(end._find_edge_leaves(horizontal)[1])
        else
          leaves[1].push(end)
      else
        # if we are a column and someone wants the horizontal edges,
        # we return the horizontal edges from all of our children
        for child in children
          if child instanceof Box
            child_leaves = child._find_edge_leaves(horizontal)
            leaves[0] = leaves[0].concat(child_leaves[0])
            leaves[1] = leaves[1].concat(child_leaves[1])
          else
            leaves[0].push(child)
            leaves[1].push(child)

    # console.log("  start leaves ", _.map(leaves[0], (leaf) -> leaf.id))
    # console.log("  end leaves ", _.map(leaves[1], (leaf) -> leaf.id))

    return leaves

  _align_outer_edges_constraints: (horizontal) ->
    # console.log("#{if horizontal then 'horizontal' else 'vertical'} outer edge constraints in #{@get_layoutable_children().length}-#{@type}")

    [start_leaves, end_leaves] = @_find_edge_leaves(horizontal)

    if horizontal
      start_variable = 'on-left-edge-align'
      end_variable = 'on-right-edge-align'
    else
      start_variable = 'on-top-edge-align'
      end_variable = 'on-bottom-edge-align'

    collect_vars = (leaves, name) ->
      #console.log("collecting #{name} in ", leaves)
      edges = []
      for leaf in leaves
        vars = leaf.get_constrained_variables()
        if name of vars
          edges.push(vars[name])
          #vars[name]['_debug'] = "#{name} from #{leaf.id}"
      edges

    start_edges = collect_vars(start_leaves, start_variable)
    end_edges = collect_vars(end_leaves, end_variable)

    result = []
    add_all_equal = (edges) ->
      if edges.length > 1
        first = edges[0]
        for i in [1...edges.length]
          edge = edges[i]
          #console.log("  constraining #{first._debug} == #{edge._debug}")
          result.push(EQ([-1, first], edge))
        null # prevent coffeescript from making a tmp array

    add_all_equal(start_edges)
    add_all_equal(end_edges)

    # console.log("computed constraints ", result)

    return result

  _box_insets_from_child_insets: (horizontal, child_variable_prefix, our_variable_prefix) ->
    [start_leaves, end_leaves] = @_find_edge_leaves(horizontal)

    if horizontal
      start_variable = "#{child_variable_prefix}-left"
      end_variable = "#{child_variable_prefix}-right"
      our_start = @["#{our_variable_prefix}_left"]
      our_end = @["#{our_variable_prefix}_right"]
    else
      start_variable = "#{child_variable_prefix}-top"
      end_variable = "#{child_variable_prefix}-bottom"
      our_start = @["#{our_variable_prefix}_top"]
      our_end = @["#{our_variable_prefix}_bottom"]

    result = []
    add_constraints = (ours, leaves, name) ->
      edges = []
      for leaf in leaves
        vars = leaf.get_constrained_variables()
        if name of vars
          result.push(EQ([-1, ours], vars[name]))
      null # prevent coffeescript from making a tmp array

    add_constraints(our_start, start_leaves, start_variable)
    add_constraints(our_end, end_leaves, end_variable)

    return result

  _box_equal_size_bounds: (horizontal) ->
    @_box_insets_from_child_insets(horizontal, 'box-equal-size', '_box_equal_size')

  set_dom_origin: (left, top) ->
    @set({ dom_left: left, dom_top: top })

  variables_updated: () ->
    for child in @get_layoutable_children()
      [left, top] = @_ensure_origin_variables(child)
      child.set_dom_origin(left._value, top._value)
      child.variables_updated()

    # hack to force re-render
    @trigger('change')


mixin_layoutable(Box)

module.exports =
  Model: Box
