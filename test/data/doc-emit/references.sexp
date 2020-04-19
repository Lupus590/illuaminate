((body (name references)
  (contents
   (table (my_term ((body table)))
    (unknown_1 ((body (args)) (see (ref unknown) (label unknown))))
    (unknown_2
     ((description
       "See <illuaminate:ref link='unknown' style='code'>unknown</illuaminate:ref> and <illuaminate:ref link='unknown' style='text'>custom label</illuaminate:ref>.\n\n")
      (body (args))))
    (term_1
     ((body (args))
      (see (ref ((in-module references) (name v:my_term)))
       (label references.my_term))
      (see (ref ((in-module references) (name v:my_term))) (label my_term))))
    (term_2
     ((description
       "See <illuaminate:ref module='references' sec='v:my_term' style='code'>my_term</illuaminate:ref>, <illuaminate:ref module='references' sec='v:my_term' style='code'>references.my_term</illuaminate:ref> and <illuaminate:ref module='references' sec='v:my_term' style='text'>custom label</illuaminate:ref>.\n\n")
      (body (args))))
    (type_1
     ((body (args))
      (see (ref ((in-module references) (name v:my_term)))
       (label references.my_term))
      (see (ref ((in-module references) (name v:my_term))) (label my_term))))
    (type_2
     ((description
       "See <illuaminate:ref module='references' sec='ty:MyType' style='code'>MyType</illuaminate:ref> and <illuaminate:ref module='references' sec='ty:MyType' style='code'>references.MyType</illuaminate:ref>\n\n")
      (body (args))))
    (type_3
     ((description
       "See <illuaminate:ref module='references' sec='ty:MyType' style='code'>MyType</illuaminate:ref> and <illuaminate:ref module='references' sec='ty:MyType' style='code'>references.MyType</illuaminate:ref>\n\n")
      (body
       (returns
        ((type ((in-module references) (name ty:MyType))) (description ))))))
    (method_1
     ((description
       "See <illuaminate:ref module='references' sec='ty:MyType:meth' style='code'>MyType:meth</illuaminate:ref> and <illuaminate:ref link='MyType.meth' style='code'>MyType.meth</illuaminate:ref>\n\n")
      (body (args))))
    (builtin_1
     ((body (args)) (see (ref ((name number))) (label number))
      (see
       (ref
        ((name string) (url https://www.lua.org/manual/5.1/manual.html#5.4)))
       (label string))
      (see
       (ref
        ((name string.match)
         (url https://www.lua.org/manual/5.1/manual.html#string.match)))
       (label string.match))))
    (builtin_2
     ((description
       "<illuaminate:ref href='https://www.lua.org/manual/5.1/manual.html#string.match' style='code'>string.match</illuaminate:ref>, <illuaminate:ref href='https://www.lua.org/manual/5.1/manual.html#5.4' style='code'>string</illuaminate:ref> and <illuaminate:ref style='code'>number</illuaminate:ref>\n\n")
      (body (args))))
    (module_1
     ((description
       "<illuaminate:ref module='references' style='code'>references</illuaminate:ref>\n\n")
      (body (args))))))
  (type
   (body (name MyType)
    (member (name meth) (method) (value ((body ((args) (self))))))))))