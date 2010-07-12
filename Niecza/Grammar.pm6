use STD;

class Niecza;
grammar Grammar is STD { # viv doesn't handle :: in definitions well atm

method p6class () { ::Niecza::Grammar::P6 }

grammar P6 is STD::P6 {
    method unitstart() {
        %*LANG<Q> = ::Niecza::Grammar::Q ;
        %*LANG<MAIN> = ::Niecza::Grammar::P6 ;
        self;
    }

    token statement_prefix:sym<PRE-INIT>
        { :my %*MYSTERY; <sym> <.spacey> <blast> <.explain_mystery> }
    token statement_control:sym<PRELUDE>
        { <sym> <.spacey> <quibble($¢.cursor_fresh( %*LANG<Q> ).tweak(:NIL))> }
}

grammar Q is STD::Q {
    #}

    multi method tweak(:$NIL!) { self.cursor_fresh( ::Niecza::Grammar::NIL ) }
}

# mnemonic characters: (@, !, =) fetch, store, lvalue.
# (l) lexical (L) raw lexical
grammar NIL is STD {
    rule nibbler { [ <insn> ]* }

    token category:insn { <sym> }
    proto token insn { <...> }

    token varid {
        [ <sigil> <twigil>? ]? <identifier> |
            <?before "'"> [ :lang(%*LANG<MAIN>) <quote> ]
    }

    token clrid { <ident>**'.' <clrgeneric>? <clrqual>* }
    token clrgeneric { '<' <clrid>**',' '>' }
    token clrqual { '[]' }

    token up { '^' * }
    token voidmark { ':v' }

    token lexdecl { [ \h* <varid> \h* ] ** ',' ':' \h* <clrid> \h* }
    token insn:lextypes { 'LEXICALS:' <lexdecl> ** ',' \h* \n }

    token insn:string_var { "=" <?before <[ ' " ]>> [ :lang(%*LANG<MAIN>) <quote> ] }
    token insn:clr_string { <?before <[ ' " ]>> [ :lang(%*LANG<MAIN>) <quote> ] }
    token insn:clr_int { $<sign>=[<[ - + ]>?] <decint> }
    token insn:label { ':'  {} <decint> }
    token insn:goto  { '->' {} <decint> }

    token insn:lexget { 'L@' {} <up> <varid> }
    token insn:lexput { 'L!' {} <up> <varid> }
    token insn:how { <sym> }
    token insn:callframe { <sym> }
    token insn:wrap { <sym> }
    token insn:wrapobj { <sym> }
    token insn:fetch { '@' }
    token insn:dup_fetch { 'dup@' }
    token insn:pos { '=[' <?> ~ ']' <decint> }
    token insn:clone_lex { 'CLONE:' [ \h* <varid> \h* ] ** ',' \h* \n }
    token insn:copy_lex { 'COPY:' [ \h* <varid> \h* ] ** ',' \h* \n }
    token insn:call_method { '.method/' {} <decint> ':' <identifier> <voidmark>? }
    token insn:call_sub { '.call/' {} <decint> <voidmark>? }
    token insn:tail_call_sub { '.tailcall/' {} <decint> }
    token insn:unwrap { <sym> ':' {} <clrid> }
    token insn:new { <sym> '/' {} <decint> ':' <clrid> }
    token insn:box { <sym> ':' {} <varid> }
    token insn:unbox { <sym> ':' {} <clrid> }
    token insn:clr_field_get { '@.' {} <varid> }
    token insn:clr_field_set { '!.' {} <varid> }
    token insn:clr_index_get { '@[' {} <varid>? ']' }
    token insn:clr_index_set { '![' {} <varid>? ']' }
    token insn:attr_get { '@!' {} <varid> }
    token insn:attr_set { '!!' {} <varid> }
    token insn:attr_raw { '=!' {} <varid> }
    token insn:cast { <sym> ':' {} <clrid> }
    token insn:clr_call_direct { '.plaincall/' {} <decint> ':' <clrid> }
    token insn:clr_call_virt { '.virtcall/' {} <decint> ':' <clrid> }
    token insn:clr_sfield_get { 'F@' {} <clrid> }
    token insn:clr_sfield_set { 'F!' {} <clrid> }
    token insn:return { <sym> '/' (<[ 0 1 ]>) }
    token insn:push_null { 'null:' {} <clrid> }
}

}

# vim: ft=
