--- @module references

local MyType = {} --- @type MyType

function MyType:meth() end

return {
  my_term = {},

  --- @see unknown
  unknown_1 = function() end,

  --- See @{unknown}
  unknown_2 = function() end,

  --- @see my_term
  -- @see references.my_term
  term_1 = function() end,

  --- See @{my_term} and @{references.my_term}
  term_2 = function() end,

  --- @see my_term
  -- @see references.my_term
  type_1 = function() end,

  --- See @{MyType} and @{references.MyType}
  type_2 = function() end,

  --- See @{MyType} and @{references.MyType}
  -- @treturn MyType
  type_3 = function() end,

  --- See @{MyType:meth} and @{MyType.meth}
  method_1 = function() end,

}