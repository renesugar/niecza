package Niecza::Actions;
use 5.010;
use strict;
use warnings;

use Op;
use Body;
use Unit;
use Sig;

our $AUTOLOAD;
my %carped;
sub AUTOLOAD {
    my ($cl, $M) = @_;
    if ($AUTOLOAD =~ /^Niecza::Actions::(.*)__S_\d\d\d(.*)$/) {
        my ($cat, $spec) = ($1, $2);
        my $m = "${cat}__S_$spec";
        my $a = "${cat}__S_ANY";
        if ($cl->can($m) || !$cl->can($a)) {
            return $cl->$m($M);
        } else {
            return $cl->$a($M, $spec);
        }
    }
    $M->sorry("Action method $AUTOLOAD not yet implemented") unless $carped{$AUTOLOAD}++;
}

sub ws { }
sub vws { }
sub unv { }
sub comment { }
sub comment__S_Sharp { }
sub spacey { }
sub unspacey { }
sub nofun { }
sub curlycheck { }
sub pod_comment { }
sub infixstopper { }

sub decint { my ($cl, $M) = @_;
    $M->{_ast} = eval $M->Str; # XXX use a real string parser
}

sub integer { my ($cl, $M) = @_;
    $M->{_ast} =
        ($M->{decint} // $M->{octint} // $M->{hexint} // $M->{binint})->{_ast};
}

sub number { my ($cl, $M) = @_;
    my $child = $M->{integer} // $M->{dec_number} // $M->{rad_number};
    $M->{_ast} = $child ? $child->{_ast} :
        ($M->Str eq 'NaN') ? (1e99999/1e99999) : (1e99999);
}

# Value :: Op
sub value { }
sub value__S_number { my ($cl, $M) = @_;
    # TODO: Implement the rest of the numeric hierarchy once MMD exists
    $M->{_ast} = Op::Num->new(value => $M->{number}{_ast});
}

sub value__S_quote { my ($cl, $M) = @_;
    $M->{_ast} = $M->{quote}{_ast};
}

sub ident { my ($cl, $M) = @_;
    $M->{_ast} = $M->Str;
}

sub identifier { my ($cl, $M) = @_;
    $M->{_ast} = $M->Str;
}

# Either String Op
sub morename { my ($cl, $M) = @_;
    $M->{_ast} = $M->{identifier} ? $M->{identifier}{_ast} : $M->{EXPR}{_ast};
}

# { dc: Bool, names: [Either String Op] }
sub name { my ($cl, $M) = @_;
    my @names = map { $_->{_ast} } @{ $M->{morename} };
    unshift @names, $M->{identifier}{_ast} if $M->{identifier};
    $M->{_ast} = { dc => !($M->{identifier}), names => \@names };
}

sub longname {} # look at the children yourself
sub deflongname {}

sub mangle_longname { my ($cl, $M) = @_;
    if ($M->{name}{_ast}{dc} || @{ $M->{name}{_ast}{names} } > 1) {
        $M->sorry("Multipart names not yet supported");
        return "";
    }

    my ($n) = @{ $M->{name}{_ast}{names} };

    for my $cp (@{ $M->{colonpair} }) {
        my $k = $cp->{k};
        if (ref $cp->{v}) {
            $n .= ":" . $cp->{k};
            $n .= $cp->{v}{qpvalue} // do {
                $M->sorry("Invalid colonpair used as name extension");
                "";
            }
        } else {
            # STD seems to think term:name is term:sym<name>.  Needs speccy
            # clarification.
            $M->sorry("Boolean colonpairs as name extensions NYI");
        }
    }

    $n;
}

sub desigilname { my ($cl, $M) = @_;
    if ($M->{variable}) {
        $M->sorry("Truncated contextualizer syntax NYI");
        return;
    }

    $M->{_ast} = $cl->mangle_longname($M->{longname});
}

sub stopper { }

# quote :: Op
sub quote {}

sub quote__S_Double_Double { my ($cl, $M) = @_;
    $M->{_ast} = $M->{nibble}{_ast};
}

sub quote__S_Single_Single { my ($cl, $M) = @_;
    $M->{_ast} = $M->{nibble}{_ast};
}

sub quote__S_qq { my ($cl, $M) = @_;
    $M->{_ast} = $M->{quibble}{_ast};
}

sub quote__S_q { my ($cl, $M) = @_;
    $M->{_ast} = $M->{quibble}{_ast};
}

sub quote__S_Q { my ($cl, $M) = @_;
    $M->{_ast} = $M->{quibble}{nibble}{_ast};
}

sub nibbler { my ($cl, $M) = @_;
    if ($M->isa('STD::Regex')) {
        $M->{_ast} = $M->{EXPR}{_ast};
    } elsif ($M->isa('Niecza::Grammar::NIL')) {
        $M->{_ast} = Op::NIL->new(code => [map { @{$_->{_ast}} } @{$M->{insn}}]);
    } else {
        # garden variety nibbler
        my $str = "";
        for my $n (@{ $M->{nibbles} }) {
            if ($n->isa('Str')) {
                $str .= $n->{TEXT};
            } else {
                $M->sorry("Non-literal contents of strings NYI");
            }
        }
        $M->{_ast} = Op::StringLiteral->new(text => $str);
    }
}

sub circumfix { }
sub circumfix__S_Lt_Gt { my ($cl, $M) = @_;
    my $sl = $M->{nibble}{_ast};

    if (!$sl->isa('Op::StringLiteral') || ($sl->text =~ /\S\s\S/)) {
        $M->sorry("Word splitting NYI");
        return;
    }

    my ($t) = $sl->text =~ /^\s*(.*?)\s*$/;

    $M->{_ast} = Op::StringLiteral->new(text => $t);
    $M->{qpvalue} = '<' . $t . '>';
}
sub circumfix__S_LtLt_GtGt { goto &circumfix__S_Lt_Gt }

sub circumfix__S_Paren_Thesis { my ($cl, $M) = @_;
    $M->{_ast} = Op::StatementList->new(children => 
        [ map { $_ ? ($_->paren) : () } @{ $M->{semilist}{_ast} } ]);
}

sub circumfix__S_Cur_Ly { my ($cl, $M) = @_;
    $M->{_ast} = $cl->block_to_immediate($M->{pblock}{_ast});
}

sub infixish { my ($cl, $M) = @_;
    $M->sorry("Metaoperators NYI") if $M->{infix_postfix_meta_operator}[0];
    $M->sorry("Adverbs NYI") if $M->{colonpair};
}
sub INFIX { my ($cl, $M) = @_;
    my ($l,$s,$r) = ($M->{left}{_ast}, $M->{infix}{sym}, $M->{right}{_ast});
    if ($s eq ':=') { #XXX macro
        $M->{_ast} = Op::Bind->new(lhs => $l, rhs => $r, readonly => 0);
        return;
    }
    if ($s eq ',') {
        #XXX STD bug causes , in setting to be parsed as left assoc
        my @r;
        push @r, ($l->isa('Op::CallSub') && $l->splittable_parcel) ?
            @{ $l->positionals } : ($l);
        push @r, ($r->isa('Op::CallSub') && $r->splittable_parcel) ?
            @{ $r->positionals } : ($r);
        $M->{_ast} = Op::CallSub->new(
            invocant => Op::Lexical->new(name => '&infix:<,>'),
            positionals => \@r, splittable_parcel => 1);
        return;
    }
    $M->{_ast} = Op::CallSub->new(
        invocant => Op::Lexical->new(name => "&infix:<$s>"),
        positionals => [ $l, $r ]);
}

sub CHAIN { my ($cl, $M) = @_;
    if (@{ $M->{chain} } != 3) {
        $M->sorry('Chaining not yet implemented');
        return;
    }

    $M->{_ast} = Op::CallSub->new(
        invocant => Op::Lexical->new(name => '&infix:<' . $M->{chain}[1]{sym} . '>'),
        positionals => [ $M->{chain}[0]{_ast}, $M->{chain}[2]{_ast} ]);
}

sub LIST { my ($cl, $M) = @_;
    # STD guarantees that all elements of delims have the same sym
    # the last item may have an ast of undef due to nulltermish
    $M->{_ast} = Op::CallSub->new(
        invocant => Op::Lexical->new(name => '&infix:<' . $M->{delims}[0]{sym} . '>'),
        positionals => [ grep { defined } map { $_->{_ast} } @{ $M->{list} } ],
        splittable_parcel => ($M->{delims}[0]{sym} eq ','));
}

sub POSTFIX { my ($cl, $M) = @_;
    my $op = $M->{_ast};
    if ($op->{postfix}) {
        $M->{_ast} = Op::CallSub->new(
            invocant => Op::Lexical->new(name => "&postfix:<" . $op->{postfix} . ">"),
            positionals => [ $M->{arg}{_ast} ]);
    } elsif ($op->{name} && $op->{name} =~ /^(?:HOW|WHAT)$/) {
        if ($op->{args}) {
            $M->sorry("Interrogative operator " . $op->{name} .
                " does not take arguments");
            return;
        }
        $M->{_ast} = Op::Interrogative->new(
            receiver => $M->{arg}{_ast},
            name => $op->{name});
    } elsif ($op->{name}) {
        $M->{_ast} = Op::CallMethod->new(
            receiver => $M->{arg}{_ast},
            name => $op->{name},
            positionals => $op->{args} // []);
    } else {
        $M->sorry("Unhandled postop type");
    }
}

sub PREFIX { my ($cl, $M) = @_;
    $M->{_ast} = Op::CallSub->new(
        invocant => Op::Lexical->new(name => '&prefix:<' . $M->{sym} . '>'),
        positionals => [ $M->{arg}{_ast} ]);
}

# infix et al just parse the operator itself
sub infix { }
sub infix__S_ANY { }

sub prefix { }
sub prefix__S_ANY { }

sub postfix { }
sub postfix__S_ANY { }

sub postcircumfix { }

sub postop { my ($cl, $M) = @_;
    $M->{_ast} = $M->{sym};
}
sub POST { my ($cl, $M) = @_;
    $M->{_ast} = $M->{dotty}{_ast} if $M->{dotty};
    $M->{_ast} = $M->{privop}{_ast} if $M->{privop};
    $M->{_ast} = { postfix => $M->{postop}{_ast} } if $M->{postop};
}

sub PRE { }

sub methodop { my ($cl, $M) = @_;
    my %r;
    $r{name}  = $cl->mangle_longname($M->{longname}) if $M->{longname};
    $r{quote} = $M->{quote}{_ast} if $M->{quote};
    $r{ref}   = $M->{variable}{_ast}{term} if $M->{variable};

    $r{args}  = $M->{args}[0]{_ast}[0] if $M->{args}[0];
    $r{args}  = $M->{arglist}[0]{_ast} if $M->{arglist}[0];

    $M->{_ast} = \%r;
}

sub dottyop { my ($cl, $M) = @_;
    if ($M->{colonpair}) {
        $M->sorry("Colonpair dotties NYI");
        return;
    }

    $M->{_ast} = $M->{methodop}{_ast} if $M->{methodop};
    $M->{_ast} = { postfix => $M->{postop}{_ast} } if $M->{postop};
}

sub privop { my ($cl, $M) = @_;
    $M->{_ast} = { %{ $M->{methodop}{_ast} }, private => 1 };
}

sub dotty { }
sub dotty__S_Dot { my ($cl, $M) = @_;
    $M->{_ast} = $M->{dottyop}{_ast};
}

sub coloncircumfix { my ($cl, $M) = @_;
    $M->{_ast} = $M->{circumfix}{_ast};
    $M->{qpvalue} = $M->{circumfix}{qpvalue};
}

sub colonpair { }

# term :: Op
sub term { }

sub term__S_value { my ($cl, $M) = @_;
    $M->{_ast} = $M->{value}{_ast};
}

sub term__S_identifier { my ($cl, $M) = @_;
    my $id  = $M->{identifier}{_ast};
    my $sal = $M->{args}{_ast} // [];  # TODO: support zero-D slicels

    if (@$sal > 1) {
        $M->sorry("Slicel lists are NYI");
        return;
    }

    if ($M->is_name($M->{identifier}->Str)) {
        $M->{_ast} = Op::Lexical->new(name => $id);
        return;
    }

    my $args = $sal->[0] // [];

    $M->{_ast} = Op::CallSub->new(
        invocant => Op::Lexical->new(name => '&' . $id),
        positionals => $args);
}

sub term__S_self { my ($cl, $M) = @_;
    $M->{_ast} = Op::Lexical->new(name => 'self');
}

sub term__S_circumfix { my ($cl, $M) = @_;
    $M->{_ast} = $M->{circumfix}{_ast};
}

sub term__S_scope_declarator { my ($cl, $M) = @_;
    $M->{_ast} = $M->{scope_declarator}{_ast};
}

sub term__S_multi_declarator { my ($cl, $M) = @_;
    $M->{_ast} = $M->{multi_declarator}{_ast};
}

sub term__S_package_declarator { my ($cl, $M) = @_;
    $M->{_ast} = $M->{package_declarator}{_ast};
}

sub term__S_routine_declarator { my ($cl, $M) = @_;
    $M->{_ast} = $M->{routine_declarator}{_ast};
}

sub term__S_regex_declarator { my ($cl, $M) = @_;
    $M->{_ast} = $M->{regex_declarator}{_ast};
}

sub term__S_type_declarator { my ($cl, $M) = @_;
    $M->{_ast} = $M->{type_declarator}{_ast};
}

sub term__S_dotty { my ($cl, $M) = @_;
    $M->{_ast} = $M->{dotty}{_ast};
}

sub term__S_capterm { my ($cl, $M) = @_;
    $M->{_ast} = $M->{capterm}{_ast};
}

sub term__S_sigterm { my ($cl, $M) = @_;
    $M->{_ast} = $M->{sigterm}{_ast};
}

sub term__S_statement_prefix { my ($cl, $M) = @_;
    $M->{_ast} = $M->{statement_prefix}{_ast};
}

sub term__S_variable { my ($cl, $M) = @_;
    $M->{_ast} = $M->{variable}{_ast}{term};
}

sub term__S_DotDotDot { my ($cl, $M) = @_;
    $M->{_ast} = Op::Yada->new(kind => '...');
}

sub term__S_BangBangBang { my ($cl, $M) = @_;
    $M->{_ast} = Op::Yada->new(kind => '!!!');
}

sub term__S_QuestionQuestionQuestion { my ($cl, $M) = @_;
    $M->{_ast} = Op::Yada->new(kind => '???');
}

sub term__S_YOU_ARE_HERE { my ($cl, $M) = @_;
    push @{ $::CURLEX->{'!decls'} //= [] },
        Decl::RunMainline->new;
    $::CURLEX->{'!slots'}{'!mainline'} = 1;
    $M->{_ast} = Op::CallSub->new(
        invocant => Op::Lexical->new(name => '!mainline'));
}

sub variable { my ($cl, $M) = @_;
    my $sigil = $M->{sigil} ? $M->{sigil}->Str : substr($M->Str, 0, 1);
    if ($M->{twigil}[0]) {
        $M->sorry("Twigils NYI");
        return;
    }
    if (!$M->{desigilname}) {
        $M->sorry("Non-simple variables NYI");
        return;
    }
    my $sl = $sigil . $M->{desigilname}{_ast};
    $M->{_ast} = {
        term => Op::Lexical->new(name => $sl),
        decl_slot => $sl,
    };
}

sub param_sep {}

# :: Sig::Target
sub param_var { my ($cl, $M) = @_;
    if ($M->{signature}) {
        $M->sorry('Sub-signatures NYI');
        return;
    }
    if ($M->{twigil}[0] || ($M->{sigil}->Str ne '$')) {
        $M->sorry('Non bare scalar targets NYI');
        return;
    }
    $M->{_ast} = Sig::Target->new(slot =>
        $M->{name}[0] ? ('$' . $M->{name}[0]->Str) : undef);
}

# :: Sig::Parameter
sub parameter { my ($cl, $M) = @_;
    if (@{ $M->{type_constraint} } > 0) {
        $M->sorry('Parameter type constraints NYI');
        return;
    }

    if (@{ $M->{trait} } > 0) {
        $M->sorry('Parameter traits NYI');
        return;
    }

    if (@{ $M->{post_constraint} } > 0) {
        $M->sorry('Parameter post constraints NYI');
        return;
    }

    if ($M->{default_value}[0]) {
        $M->sorry('Default values NYI');
        return;
    }

    if ($M->{named_param}) {
        $M->sorry('Named parameters NYI');
        return;
    }

    if ($M->{quant} ne '' || $M->{kind} ne '!') {
        $M->sorry('Exotic parameters NYI');
        return;
    }

    $M->{_ast} = Sig::Parameter->new(target => $M->{param_var}{_ast});
}

# signatures exist in several syntactic contexts so just make an object for now
sub signature { my ($cl, $M) = @_;
    if ($M->{type_constraint}[0]) {
        $M->sorry("Return type constraints NYI");
        return;
    }

    if ($M->{param_var}) {
        $M->sorry('\| signatures NYI');
        return;
    }

    for (@{ $M->{param_sep} }) {
        if ($_->Str !~ /,/) {
            $M->sorry('Parameter separator ' . $_->Str . ' NYI');
            return;
        }
    }

    $M->{_ast} = Sig->new(params =>
        [map { $_->{_ast} } @{ $M->{parameter} }]);
}

sub multisig { my ($cl, $M) = @_;
    if (@{ $M->{signature} } != 1) {
        $M->sorry("Multiple signatures NYI");
        return;
    }
    $M->{_ast} = $M->{signature}[0]{_ast};
}

sub voidmark { my ($cl, $M) = @_;
    $M->{_ast} = 1;
}

sub up { my ($cl, $M) = @_;
    $M->{_ast} = length ($M->Str);
}

sub lexdecl { my ($cl, $M) = @_;
    $M->{_ast} = [ map { $_->{_ast}, $M->{clrid}->Str } @{ $M->{varid} } ];
}

# :: [row of NIL op]
sub insn {}
sub insn__S_lextypes { my ($cl, $M) = @_;
    $M->{_ast} = [[ lextypes => map { @{ $_->{_ast} } } @{ $M->{lexdecl} } ]];
}

sub insn__S_clone_lex { my ($cl, $M) = @_;
    $M->{_ast} = [ map { [ clone_lex => $_->{_ast} ] } @{ $M->{varid} } ];
}

sub insn__S_copy_lex { my ($cl, $M) = @_;
    $M->{_ast} = [ map { [ copy_lex => $_->{_ast} ] } @{ $M->{varid} } ];
}

sub insn__S_string_var { my ($cl, $M) = @_;
    if (!$M->{quote}{_ast}->isa('Op::StringLiteral')) {
        $M->sorry("Strings used in NIL code must be compile time constants");
    }
    $M->{_ast} = [[ string_var => $M->{quote}{_ast}->text ]];
}

sub insn__S_clr_string { my ($cl, $M) = @_;
    if (!$M->{quote}{_ast}->isa('Op::StringLiteral')) {
        $M->sorry("Strings used in NIL code must be compile time constants");
    }
    $M->{_ast} = [[ clr_string => $M->{quote}{_ast}->text ]];
}

sub insn__S_clr_int { my ($cl, $M) = @_;
    my $s = ($M->{sign}->Str eq '-') ? -1 : +1;
    $M->{_ast} = [[ clr_int => $s * $M->{decint}{_ast} ]];
}

# the negatives here are somewhat of a cheat.
sub insn__S_label { my ($cl, $M) = @_;
    $M->{_ast} = [[ labelhere => -$M->{decint}{_ast} ]];
}

sub insn__S_goto { my ($cl, $M) = @_;
    $M->{_ast} = [[ goto => -$M->{decint}{_ast} ]];
}

sub insn__S_cgoto { my ($cl, $M) = @_;
    $M->{_ast} = [[ cgoto => -$M->{decint}{_ast} ]];
}

sub insn__S_ncgoto { my ($cl, $M) = @_;
    $M->{_ast} = [[ ncgoto => -$M->{decint}{_ast} ]];
}

my $labelid = 1000;
sub insn__S_if { my ($cl, $M) = @_;
    my @r;
    my $end1 = $labelid++;
    my $end2 = $labelid++;
    push @r, [ 'ncgoto', -$end1 ];
    push @r, @{ $M->{nibbler}[0]{_ast}->code };
    if ($M->{nibbler}[1]) {
        push @r, [ 'goto', -$end2 ], [ 'labelhere', -$end1 ];
        push @r, @{ $M->{nibbler}[1]{_ast}->code };
        push @r, [ 'labelhere', -$end2 ];
    } else {
        push @r, [ 'labelhere', -$end1 ];
    }
    $M->{_ast} = \@r;
}

sub insn__S_begin { my ($cl, $M) = @_;
    my @r;
    my $b1 = $labelid++;
    push @r, [ 'labelhere', -$b1 ];
    push @r, @{ $M->{nibbler}[0]{_ast}->code };
    if ($M->{while}) {
        my $b2 = $labelid++;
        push @r, [ 'ncgoto', -$b2 ];
        push @r, @{ $M->{nibbler}[1]{_ast}->code };
        push @r, [ 'goto', -$b1 ], [ 'labelhere', -$b2 ];
    } elsif ($M->{until}) {
        push @r, [ 'ncgoto', -$b1 ];
    } elsif ($M->{again}) {
        push @r, [ 'goto', -$b1 ];
    }
    $M->{_ast} = \@r;
}

sub insn__S_lex { my ($cl, $M) = @_;
    $M->{_ast} = [[ lex => $M->{up}{_ast}, $M->{varid}{_ast} ]];
}

sub insn__S_lexget { my ($cl, $M) = @_;
    $M->{_ast} = [[ lexget => $M->{up}{_ast}, $M->{varid}{_ast} ]];
}

sub insn__S_lexput { my ($cl, $M) = @_;
    $M->{_ast} = [[ lexput => $M->{up}{_ast}, $M->{varid}{_ast} ]];
}

sub insn__S_how { my ($cl, $M) = @_;
    $M->{_ast} = [[ 'how' ]];
}

sub insn__S_callframe { my ($cl, $M) = @_;
    $M->{_ast} = [[ 'callframe' ]];
}

sub insn__S_fetch { my ($cl, $M) = @_;
    $M->{_ast} = [[ 'fetch' ]];
}

sub insn__S_store { my ($cl, $M) = @_;
    $M->{_ast} = [[ 'store' ]];
}

sub insn__S_dup_fetch { my ($cl, $M) = @_;
    $M->{_ast} = [[ 'dup_fetch' ]];
}

sub insn__S_wrap { my ($cl, $M) = @_;
    $M->{_ast} = [[ 'clr_wrap' ]];
}

sub insn__S_wrapobj { my ($cl, $M) = @_;
    $M->{_ast} = [[ 'clr_call_direct', 'Kernel.NewROVar', 1 ]];
}

sub insn__S_pos { my ($cl, $M) = @_;
    $M->{_ast} = [[ pos => $M->{decint}{_ast} ]];
}

sub insn__S_call_method { my ($cl, $M) = @_;
    $M->{_ast} = [[ call_method => !$M->{voidmark}[0], $M->{identifier}->Str,
            $M->{decint}{_ast} ]];
}

sub insn__S_call_sub { my ($cl, $M) = @_;
    $M->{_ast} = [[ call_sub => !$M->{voidmark}[0], $M->{decint}{_ast} ]];
}

sub insn__S_tail_call_sub { my ($cl, $M) = @_;
    $M->{_ast} = [[ tail_call_sub => $M->{decint}{_ast} ]];
}

sub insn__S_clr_call_direct { my ($cl, $M) = @_;
    $M->{_ast} = [[ clr_call_direct => $M->{clrid}->Str, $M->{decint}{_ast} ]];
}

sub insn__S_clr_call_virt { my ($cl, $M) = @_;
    $M->{_ast} = [[ clr_call_virt => $M->{clrid}->Str, $M->{decint}{_ast} ]];
}

sub insn__S_unwrap { my ($cl, $M) = @_;
    $M->{_ast} = [[ clr_unwrap => $M->{clrid}->Str ]];
}

sub insn__S_box { my ($cl, $M) = @_;
    $M->{_ast} = [[ box => $M->{varid}->Str ]];
}

sub insn__S_unbox { my ($cl, $M) = @_;
    $M->{_ast} = [[ unbox => $M->{clrid}->Str ]];
}

sub insn__S_clr_sfield_get { my ($cl, $M) = @_;
    $M->{_ast} = [[ clr_sfield_get => $M->{clrid}->Str ]];
}

sub insn__S_clr_sfield_set { my ($cl, $M) = @_;
    $M->{_ast} = [[ clr_sfield_set => $M->{clrid}->Str ]];
}

sub insn__S_new { my ($cl, $M) = @_;
    $M->{_ast} = [[ clr_new => $M->{clrid}->Str, $M->{decint}{_ast} ]];
}

sub insn__S_clr_field_get { my ($cl, $M) = @_;
    $M->{_ast} = [[ clr_field_get => $M->{varid}{_ast} ]];
}

sub insn__S_clr_field_set { my ($cl, $M) = @_;
    $M->{_ast} = [[ clr_field_set => $M->{varid}{_ast} ]];
}

sub insn__S_clr_index_get { my ($cl, $M) = @_;
    $M->{_ast} = [[ clr_index_get => ($M->{varid}[0] ? ($M->{varid}[0]{_ast}) : ()) ]];
}

sub insn__S_clr_index_set { my ($cl, $M) = @_;
    $M->{_ast} = [[ clr_index_set => ($M->{varid}[0] ? ($M->{varid}[0]{_ast}) : ()) ]];
}

sub insn__S_arith { my ($cl, $M) = @_;
    $M->{_ast} = [[ clr_arith => $M->Str ]];
}

sub insn__S_compare { my ($cl, $M) = @_;
    $M->{_ast} = [[ clr_compare => $M->Str ]];
}

sub insn__S_attr_get { my ($cl, $M) = @_;
    $M->{_ast} = [[ attr_get => $M->{varid}{_ast} ]];
}

sub insn__S_attr_set { my ($cl, $M) = @_;
    $M->{_ast} = [[ attr_set => $M->{varid}{_ast} ]];
}

sub insn__S_attr_var { my ($cl, $M) = @_;
    $M->{_ast} = [[ attr_var => $M->{varid}{_ast} ]];
}

sub insn__S_cast { my ($cl, $M) = @_;
    $M->{_ast} = [[ cast => $M->{clrid}->Str ]];
}

sub insn__S_return { my ($cl, $M) = @_;
    $M->{_ast} = [[ return => $M->{0} ]];
}

sub insn__S_push_null { my ($cl, $M) = @_;
    $M->{_ast} = [[ push_null => $M->{clrid}->Str ]];
}

sub insn__S_hll { my ($cl, $M) = @_;
    $M->{_ast} = [ $M->{EXPR}{_ast} ];
}

sub clrid {}
sub clrqual {}
sub clrgeneric {}
sub varid { my ($cl, $M) = @_;
    if ($M->{quote}) {
        if (!$M->{quote}{_ast}->isa('Op::StringLiteral')) {
            $M->sorry("Strings used in NIL code must be compile time constants");
        }
        $M->{_ast} = $M->{quote}{_ast}->text;
    } else {
        $M->{_ast} = $M->Str;
    }
}
sub apostrophe {}
sub quibble {}
sub tribble {}
sub babble {}
sub quotepair {}

# We can't do much at blockoid reduce time because the context is unknown.
# Roles and subs need somewhat different code gen
sub blockoid { my ($cl, $M) = @_;
    $M->{_ast} = $M->{statementlist}{_ast};
}

sub sigil {}
sub sigil__S_Amp {}
sub sigil__S_Dollar {}
sub sigil__S_At {}
sub sigil__S_Percent {}

sub twigil {}
sub twigil__S_Equal {}
sub twigil__S_Bang {}
sub twigil__S_Dot {}
sub twigil__S_Tilde {}
sub twigil__S_Star {}
sub twigil__S_Question {}
sub twigil__S_Caret {}
sub twigil__S_Colon {}

sub terminator {}
sub terminator__S_Thesis {}
sub terminator__S_Semi {}
sub terminator__S_Ket {}
sub terminator__S_Ly {}
sub terminator__S_then {}
sub terminator__S_again {}
sub terminator__S_repeat {}
sub terminator__S_while {}
sub terminator__S_else {}
sub stdstopper {}
sub unitstopper {}
sub eat_terminator {}

sub scoped { my ($cl, $M) = @_;
    $M->{_ast} = ($M->{declarator} // $M->{regex_declarator} //
        $M->{package_declarator} // $M->{multi_declarator})->{_ast};
}

# :: Op (but adds decls)
sub declarator { my ($cl, $M) = @_;
    if ($M->{signature}) {
        $M->sorry("Signature declarations NYI");
        return;
    }
    $M->{_ast} = $M->{variable_declarator} ? $M->{variable_declarator}{_ast} :
                 $M->{routine_declarator}  ? $M->{routine_declarator}{_ast} :
                 $M->{regex_declarator}    ? $M->{regex_declarator}{_ast} :
                 $M->{type_declarator}{_ast};
}

sub scope_declarator { my ($cl, $M) = @_;
    $M->{_ast} = $M->{scoped}{_ast};
}
sub scope_declarator__S_my {}
sub scope_declarator__S_our {}
sub scope_declarator__S_augment {}
sub scope_declarator__S_supercede {}
sub scope_declarator__S_has {}
sub scope_declarator__S_state {}
sub scope_declarator__S_anon {}

sub variable_declarator { my ($cl, $M) = @_;
    if ($M->{trait}[0] || $M->{post_constraint}[0] || $M->{shape}[0]) {
        $M->sorry("Traits, postconstraints, and shapes on variable declarators NYI");
        return;
    }

    my $slot = $M->{variable}{_ast}{decl_slot};

    if (!$slot) {
        $M->sorry("Cannot apply a declarator to a non-simple variable");
        return;
    }

    my $scope = $::SCOPE // 'my';

    if ($scope eq 'augment' || $scope eq 'supercede') {
        $M->sorry("Illogical scope $scope for simple variable");
        return;
    }

    if ($scope eq 'has' || $scope eq 'our' || $scope eq 'state') {
        $M->sorry("Unsupported scope $scope for simple variable");
        return;
    }

    if ($scope eq 'anon') {
        $slot = $cl->gensym;
    }

    $::CURLEX->{'!slots'}{$slot} = 1;
    push @{ $::CURLEX->{'!decls'} //= [] },
        Decl::SimpleVar->new(slot => $slot);

    $M->{_ast} = Op::Lexical->new(name => $slot);
}

sub package_declarator {}
sub package_declarator__S_class { my ($cl, $M) = @_;
    $M->{_ast} = $M->{package_def}{_ast};
}

sub package_declarator__S_grammar { my ($cl, $M) = @_;
    $M->{_ast} = $M->{package_def}{_ast};
}

sub package_declarator__S_package { my ($cl, $M) = @_;
    $M->{_ast} = $M->{package_def}{_ast};
}

sub package_declarator__S_module { my ($cl, $M) = @_;
    $M->{_ast} = $M->{package_def}{_ast};
}

sub package_declarator__S_knowhow { my ($cl, $M) = @_;
    $M->{_ast} = $M->{package_def}{_ast};
}

sub package_declarator__S_role { my ($cl, $M) = @_;
    $M->{_ast} = $M->{package_def}{_ast};
}

sub package_declarator__S_slang { my ($cl, $M) = @_;
    $M->{_ast} = $M->{package_def}{_ast};
}

sub package_declarator__S_also { my ($cl, $M) = @_;
    push @{ $::CURLEX->{'!decls'} //= [] },
        map { $_->{_ast} } @{ $M->{trait} };
}

sub termish {}
sub nulltermish { my ($cl, $M) = @_; # for 1,2,3,
    # XXX this is insane
    $M->{term}{_ast} = $M->{term}{term}{_ast} if $M->{term};
}
sub EXPR {}

sub arglist { my ($cl, $M) = @_;
    $M->sorry("Invocant handling is NYI") if $::INVOCANT_IS;
    my $x = $M->{EXPR}{_ast};

    if ($x && $x->isa('Op::CallSub') && $x->splittable_parcel) {
        $M->{_ast} = $x->positionals;
    } else {
        $M->{_ast} = [$x];
    }
}

sub semiarglist { my ($cl, $M) = @_;
    $M->{_ast} = [ map { $_->{_ast} } @{ $M->{arglist} } ];
}

sub args { my ($cl, $M) = @_;
    if ($M->{moreargs} || $M->{semiarglist} && $M->{arglist}[0]) {
        $M->sorry("Interaction between semiargs and args is not understood");
        return;
    }

    $M->{_ast} = $M->{semiarglist} ? $M->{semiarglist}{_ast} :
        $M->{arglist}[0] ? [ $M->{arglist}[0]{_ast} ] : undef;
}

sub statement { my ($cl, $M) = @_;
    if ($M->{label} || $M->{statement_mod_cond}[0] || $M->{statement_mod_loop}[0]) {
        $M->sorry("Control is NYI");
        return;
    }

    $M->{_ast} = $M->{statement_control} ? $M->{statement_control}{_ast} :
                 $M->{EXPR} ? $M->{EXPR}{_ast} : undef;
}

sub statementlist { my ($cl, $M) = @_;
    $M->{_ast} = Op::StatementList->new(children => 
        [ grep { defined $_ } map { $_->{_ast} } @{ $M->{statement} } ]);
}

sub semilist { my ($cl, $M) = @_;
    $M->{_ast} = [  map { $_->{_ast} } @{ $M->{statement} } ];
}

sub statement_control { }
sub statement_control__S_if { my ($cl, $M) = @_;
    my $else = $M->{else}[0] ?
        $cl->block_to_immediate($M->{else}[0]{_ast}) : undef;
    my @elsif;
    for (reverse @{ $M->{elsif} }) {
        $else = Op::Conditional->new(check => $_->{_ast}[0],
            true => $cl->block_to_immediate($_->{_ast}[1]),
            false => $else);
    }
    $M->{_ast} = Op::Conditional->new(check => $M->{xblock}{_ast}[0],
        true => $cl->block_to_immediate($M->{xblock}{_ast}[1]),
        false => $else);
}

sub statement_control__S_while { my ($cl, $M) = @_;
    $M->{_ast} = Op::WhileLoop->new(check => $M->{xblock}{_ast}[0],
        body => $cl->block_to_immediate($M->{xblock}{_ast}[1]),
        until => 0, once => 0);
}

sub statement_control__S_until { my ($cl, $M) = @_;
    $M->{_ast} = Op::WhileLoop->new(check => $M->{xblock}{_ast}[0],
        body => $cl->block_to_immediate($M->{xblock}{_ast}[1]),
        until => 1, once => 0);
}

sub package_def { my ($cl, $M) = @_;
    if ($::PKGDECL ne 'class') {
        $M->sorry('Non-class package definitions are not yet supported');
        return;
    }
    my $scope = $::SCOPE;
    if (!$M->{longname}[0]) {
        $scope = 'anon';
    }
    if ($::SCOPE ne 'anon' && $::SCOPE ne 'my') {
        $M->sorry('Non-lexical class definitions are not yet supported');
        return;
    }
    my $name = $M->{longname}[0] ?
        $cl->mangle_longname($M->{longname}[0]) : 'ANON';
    my $outer = $cl->get_outer($::CURLEX);
    my $outervar = $::SCOPE eq 'my' ? $name : $cl->gensym;
    if (!$M->{decl}{stub}) {
        $outer->{'!slots'}{$outervar} = 1;
        $outer->{'!slots'}{"$outervar!HOW"} = 1;
        $outer->{'!slots'}{"$outervar!BODY"} = 1;

        my $stmts = $M->{statementlist} // $M->{blockoid};
        unshift @{ $::CURLEX->{'!decls'} //= [] },
            map { $_->{_ast} } @{ $M->{trait} };

        AUTOANY: {
            for my $d (@{ $::CURLEX->{'!decls'} //= [] }) {
                next unless $d->isa('Decl::Super');
                last AUTOANY;
            }

            push @{ $::CURLEX->{'!decls'} //= [] },
                Decl::Super->new(name => 'Any');
        }

        my $cbody = Body::Class->new(
            name    => $name,
            decls   => ($::CURLEX->{'!decls'} // []),
            enter   => ($::CURLEX->{'!enter'} // []),
            lexical => ($::CURLEX->{'!slots'} // {}),
            do      => $stmts->{_ast});
        my $cdecl = Decl::Class->new(
            name    => $name,
            var     => $outervar,
            body    => $cbody);
        push @{ $outer->{'!decls'} //= [] }, $cdecl;
        $M->{_ast} = Op::StatementList->new(
            children => [
                Op::CallSub->new(
                    invocant => Op::Lexical->new(name => $outervar . '!BODY')),
                Op::Lexical->new(name => $outervar)]);
    } else {
        $outer->{'!slots'}{$outervar} = 1;
        $outer->{'!slots'}{"$outervar!HOW"} = 1;

        push @{ $outer->{'!decls'} //= [] }, Decl::Class->new(
            name    => $name,
            var     => $outervar,
            stub    => 1);

        #XXX: What should this return?
    }
}

sub trait_mod {}
sub trait_mod__S_is { my ($cl, $M) = @_;
    my $trait = $M->{longname}->Str;

    if (!$M->is_name($trait)) {
        $M->sorry('Non-superclass is traits NYI');
        return;
    }

    if ($M->{circumfix}[0]) {
        $M->sorry('Superclasses cannot have parameters');
        return;
    }

    $M->{_ast} = Decl::Super->new(name => $trait);
}

sub trait { my ($cl, $M) = @_;
    if ($M->{colonpair}) {
        $M->sorry('Colonpair traits NYI');
        return;
    }

    $M->{_ast} = $M->{trait_mod}{_ast};
}

sub routine_declarator {}
sub routine_declarator__S_sub { my ($cl, $M) = @_;
    $M->{_ast} = $M->{routine_def}{_ast};
}
sub routine_declarator__S_method { my ($cl, $M) = @_;
    $M->{_ast} = $M->{method_def}{_ast};
}

my $next_anon_id = 0;
sub gensym { 'anon_' . ($next_anon_id++) }

sub sl_to_block { my ($cl, $ast, %args) = @_;
    my $subname = $args{subname} // 'ANON';
    if ($args{signature}) {
        for ($args{signature}->used_slots) {
            push @{ $::CURLEX->{'!decls'} //= [] },
                Decl::SimpleVar->new(slot => $_);
            $::CURLEX->{'!slots'}{$_} = 1;
        }
    }
    Body->new(
        name      => $subname,
        $args{bare} ? () : (
            decls   => ($::CURLEX->{'!decls'} // []),
            enter   => ($::CURLEX->{'!enter'} // []),
            lexical => ($::CURLEX->{'!slots'} // {})),
        signature => $args{signature},
        do        => $ast);
}

sub get_outer { my ($cl, $pad) = @_;
    $STD::ALL->{ $pad->{'OUTER::'}[0] };
}

sub block_to_immediate { my ($cl, $blk) = @_;
    Op::CallSub->new(
        invocant => $cl->block_to_closure(0, $blk),
        positionals => []);
}

sub block_to_closure { my ($cl, $uplevel, $blk, %args) = @_;
    my $outer = $uplevel ? $cl->get_outer($::CURLEX) : $::CURLEX;
    my $outer_key = $args{outer_key} // $cl->gensym;

    $outer->{'!slots'}{$outer_key} = 1 if $outer;

    unless ($args{stub}) {
        push @{ $outer->{'!decls'} //= [] },
            Decl::Sub->new(var => $outer_key, code => $blk) if $outer;
    }

    Op::Lexical->new(name => $outer_key);
}

# always a sub, though sometimes it's an implied sub after multi/proto/only
sub routine_def { my ($cl, $M) = @_;
    if ($M->{sigil}[0] && $M->{sigil}[0]->Str eq '&*') {
        $M->sorry("Contextuals NYI");
        return;
    }
    my $dln = $M->{deflongname}[0];
    if (@{ $M->{multisig} } > 1) {
        $M->sorry("Multiple multisigs (what?) NYI");
        return;
    }
    if ($M->{trait}[0]) {
        $M->sorry("Sub traits NYI");
        return;
    }
    my $scope = !$dln ? 'anon' : $::SCOPE || 'my';
    if ($scope ne 'my' && $scope ne 'our' && $scope ne 'anon') {
        $M->sorry("Illegal scope $scope for subroutine");
        return;
    }
    if ($scope eq 'our') {
        $M->sorry('Package subs NYI');
        return;
    }

    my $m = $dln ? $cl->mangle_longname($dln) : undef;

    $M->{_ast} = $cl->block_to_closure(1,
            $cl->sl_to_block(
                $M->{blockoid}{_ast},
                subname => $m,
                signature => ($M->{multisig}[0] ? $M->{multisig}[0]{_ast} : undef)),
        stub => $dln && $M->{decl}{stub},
        outer_key => (($scope eq 'my') ? "&$m" : undef));
}

sub method_def { my ($cl, $M) = @_;
    my $scope = $::SCOPE // 'has';
    $scope = 'anon' if !$M->{longname};
    my $name = $M->{longname} ? $cl->mangle_longname($M->{longname}) : undef;

    if ($M->{trait}[0] || $M->{sigil}) {
        $M->sorry("Method traits NYI");
        return;
    }
    if (@{ $M->{multisig} } > 1) {
        $M->sorry("Multiple multisigs (what?) NYI");
        return;
    }

    my $sym = ($scope eq 'my') ? ('&' . $name) : $cl->gensym;

    if ($scope eq 'augment' || $scope eq 'supercede' || $scope eq 'state') {
        $M->sorry("Illogical scope $scope for method");
        return;
    }

    if ($scope eq 'our') {
        $M->sorry("Packages NYI");
        return;
    }

    my $bl = $cl->sl_to_block($M->{blockoid}{_ast},
        subname => $name,
        signature => ($M->{multisig}[0] ?
            $M->{multisig}[0]{_ast}->for_method : undef));

    $cl->block_to_closure(1, $bl, outer_key => $sym);

    push @{ $cl->get_outer($::CURLEX)->{'!decls'} },
        Decl::HasMethod->new(name => $name, var => $sym)
            unless $scope eq 'anon';

    $M->{_ast} = Op::Lexical->new(name => $sym);
}

sub block { my ($cl, $M) = @_;
    $M->{_ast} = $cl->sl_to_block($M->{blockoid}{_ast});
}

# :: Body
sub pblock { my ($cl, $M) = @_;
    my $rw = $M->{lambda} && $M->{lambda}->Str eq '<->';
    $M->{_ast} = $cl->sl_to_block($M->{blockoid}{_ast},
        signature => ($M->{signature} ? $M->{signature}{_ast} : undef));
}

sub xblock { my ($cl, $M) = @_;
    $M->{_ast} = [ $M->{EXPR}{_ast}, $M->{pblock}{_ast} ];
}

# returns Body of 0 args
sub blast { my ($cl, $M) = @_;
    if ($M->{block}) {
        $M->{_ast} = $M->{block}{_ast};
    } else {
        $M->{_ast} = Body->new(
            name => 'ANON',
            do   => $M->{statement}{_ast});
    }
}

sub statement_prefix {}
sub statement_prefix__S_PREMinusINIT { my ($cl, $M) = @_;
    my $var = $cl->gensym;

    $::CURLEX->{'!slots'}{$var} = 1;
    push @{ $::CURLEX->{'!decls'} //= [] },
        Decl::PreInit->new(var => $var, code => $M->{blast}{_ast}, shared => 1);

    $M->{_ast} = Op::Lexical->new(name => $var);
}

sub comp_unit { my ($cl, $M) = @_;
    my $body = $cl->sl_to_block($M->{statementlist}{_ast},
        subname => 'mainline');

    $M->{_ast} = Unit->new(mainline => $body, name => $::UNITNAME,
        $::SETTING_RESUME ? (setting => $::SETTING_RESUME) : ());
}

1;
