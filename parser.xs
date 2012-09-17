#include "EXTERN.h"
#include "perl.h"
#include "callparser1.h"
#include "XSUB.h"

/* XXX replace this with a real implementation */
static I32 *new_uuid()
{
    I32 *uuid;
    int i;

    Newx(uuid, 4, I32);

    if (!PL_srand_called) {
        (void)seedDrand01((Rand_seed_t)Perl_seed(aTHX));
        PL_srand_called = TRUE;
    }

    for (i = 0; i < 4; ++i) {
        /* XXX this is terrible */
        uuid[i] = (I32)(Drand01() * (double)(2<<30));
    }

    return uuid;
}

static SV *uuid_as_string(I32 *uuid)
{
    unsigned char *uuid_bytes;

    /* XXX endianness, etc... */
    uuid_bytes = (char *)uuid;
    return newSVpvf("%02hhx%02hhx%02hhx%02hhx-%02hhx%02hhx-%02hhx%02hhx-%02hhx%02hhx-%02hhx%02hhx%02hhx%02hhx%02hhx%02hhx", uuid_bytes[0], uuid_bytes[1], uuid_bytes[2], uuid_bytes[3], uuid_bytes[4], uuid_bytes[5], uuid_bytes[6], uuid_bytes[7], uuid_bytes[8], uuid_bytes[9], uuid_bytes[10], uuid_bytes[11], uuid_bytes[12], uuid_bytes[13], uuid_bytes[14], uuid_bytes[15]);
}

struct mop_instance {
    SV *class;
    I32 *uuid;
    SV **slots;
};

void free_mop_instance(SV *instance);

int mg_free_mop_instance(SV *sv, MAGIC *mg)
{
    free_mop_instance(sv);
}

MGVTBL vtbl_instance   = { 0, 0, 0, 0, mg_free_mop_instance };
MGVTBL vtbl_slot_names = { 0, 0, 0, 0, 0 };

void attach_slot_names(SV *class, AV *slot_names)
{
    assert(SvTYPE(slot_names) == SVt_PVAV);
    sv_magicext(class, (SV *)slot_names, PERL_MAGIC_ext,
                &vtbl_slot_names, NULL, 0);
}

AV *get_slot_names_noref(SV *class)
{
    MAGIC *mg = NULL;

    if (SvTYPE(class) >= SVt_PVMG) {
        mg = mg_findext(class, PERL_MAGIC_ext, &vtbl_slot_names);
    }

    if (mg) {
        return (AV *)(mg->mg_obj);
    }
    else {
        return (AV *)sv_2mortal((SV *)newAV());
    }
}

AV *get_slot_names(SV *class_ref)
{
    assert(SvROK(class_ref));
    return get_slot_names_noref(SvRV(class_ref));
}

I32 slot_offset_for_name(AV *slot_names, SV *name)
{
    I32 slot_names_len;
    int i;

    slot_names_len = av_len(slot_names) + 1;

    for (i = 0; i < slot_names_len; ++i) {
        SV **val;

        val = av_fetch(slot_names, i, 0);
        if (val && strEQ(SvPV_nolen(*val), SvPV_nolen(name))) {
            return i;
        }
    }

    croak("couldn't find slot offset for %"SVf, name);
}

struct mop_instance *allocate_mop_instance(SV *class)
{
    struct mop_instance *instance;
    AV *slot_names;
    I32 number_of_slots;

    if (!class) {
        croak("can't set to null class");
    }

    assert(SvROK(class));

    Newxz(instance, 1, struct mop_instance);

    instance->class = SvREFCNT_inc_simple_NN(class);

    slot_names = get_slot_names(class);
    number_of_slots = av_len(slot_names) + 1;
    Newxz(instance->slots, number_of_slots, SV *);

    return instance;
}

void free_mop_instance(SV *instance_sv)
{
    struct mop_instance *instance;
    AV *slot_names;
    I32 number_of_slots;
    int i;

    instance = (struct mop_instance *)SvIVX(instance_sv);

    slot_names = get_slot_names_noref(instance_sv);
    number_of_slots = av_len(slot_names) + 1;

    SvREFCNT_dec(instance->class);
    instance->class = NULL;
    if (instance->uuid) {
        Safefree(instance->uuid);
        instance->uuid = NULL;
    }
    for (i = 0; i < number_of_slots; ++i) {
        if ((instance->slots)[i]) {
            SvREFCNT_dec((instance->slots)[i]);
        }
    }
    Safefree(instance->slots);
    instance->slots = NULL;
    Safefree(instance);
}

SV *mop_get_class(struct mop_instance *instance)
{
    assert(SvROK(instance->class));

    return instance->class;
}

void mop_set_class(struct mop_instance *instance, SV *class)
{
    SV *old_class;

    if (!class) {
        croak("can't set to null class");
    }

    assert(SvROK(class));

    old_class = instance->class;

    instance->class = SvREFCNT_inc_simple_NN(class);

    SvREFCNT_dec(old_class);

    /* XXX fix up slots array */
}

I32 *mop_get_uuid(struct mop_instance *instance)
{
    if (!instance->uuid) {
        instance->uuid = new_uuid();
    }
    return instance->uuid;
}

SV **mop_get_slots(struct mop_instance *instance)
{
    return instance->slots;
}

SV *mop_get_slot_at(struct mop_instance *instance, IV offset)
{
    return (instance->slots)[offset];
}

void mop_set_slot_at(struct mop_instance *instance, IV offset, SV *value_ref)
{
    SV *old_value;
    SV *value;

    value = SvRV(value_ref);
    old_value = (instance->slots)[offset];

    /* XXX do NULL values make sense? or do we want to store them as
     * PL_sv_undef? if we do that, should we be checking for that here to avoid
     * twiddling the refcount of PL_sv_undef? */
    if (value) {
        SvREFCNT_inc_simple_void_NN(value);
    }

    (instance->slots)[offset] = value;

    if (old_value) {
        SvREFCNT_dec(old_value);
    }
}

struct data {
    SV *indicator;
    char *package;
};

/* stolen (with modifications) from Scope::Escape::Sugar */

#define SVt_PADNAME SVt_PVMG

#ifndef COP_SEQ_RANGE_LOW_set
# define COP_SEQ_RANGE_LOW_set(sv,val) \
	do { ((XPVNV*)SvANY(sv))->xnv_u.xpad_cop_seq.xlow = val; } while(0)
# define COP_SEQ_RANGE_HIGH_set(sv,val) \
	do { ((XPVNV*)SvANY(sv))->xnv_u.xpad_cop_seq.xhigh = val; } while(0)
#endif /* !COP_SEQ_RANGE_LOW_set */

/*
 * pad handling
 *
 * The public API for the pad system is lacking any way to add items to
 * the pad.  This is a minimal implementation of the necessary facilities.
 * It doesn't warn about shadowing.
 */

#define pad_add_my_pvn(namepv, namelen, type) \
		THX_pad_add_my_pvn(aTHX_ namepv, namelen, type)
static PADOFFSET THX_pad_add_my_pvn(pTHX_
	char const *namepv, STRLEN namelen, svtype type)
{
	PADOFFSET offset;
	SV *namesv, *myvar;
	myvar = *av_fetch(PL_comppad, AvFILLp(PL_comppad) + 1, 1);
	offset = AvFILLp(PL_comppad);
	SvPADMY_on(myvar);
        (void)SvUPGRADE(myvar, type);
	PL_curpad = AvARRAY(PL_comppad);
	namesv = newSV_type(SVt_PADNAME);
	sv_setpvn(namesv, namepv, namelen);
	COP_SEQ_RANGE_LOW_set(namesv, PL_cop_seqmax);
	COP_SEQ_RANGE_HIGH_set(namesv, PERL_PADSEQ_INTRO);
	PL_cop_seqmax++;
	av_store(PL_comppad_name, offset, namesv);
	return offset;
}

#define pad_add_my_sv(namesv, type) THX_pad_add_my_sv(aTHX_ namesv, type)
static PADOFFSET THX_pad_add_my_sv(pTHX_ SV *namesv, svtype type)
{
	char const *pv;
	STRLEN len;
	pv = SvPV(namesv, len);
	return pad_add_my_pvn(pv, len, type);
}

#define pad_add_my_scalar_sv(namesv) THX_pad_add_my_sv(aTHX_ namesv, SVt_NULL)
#define pad_add_my_array_sv(namesv)  THX_pad_add_my_sv(aTHX_ namesv, SVt_PVAV)
#define pad_add_my_hash_sv(namesv)   THX_pad_add_my_sv(aTHX_ namesv, SVt_PVHV)
#define pad_add_my_scalar_pvn(namepv, namelen) \
    THX_pad_add_my_pvn(aTHX_ namepv, namelen, SVt_NULL)
#define pad_add_my_array_pvn(namepv, namelen) \
    THX_pad_add_my_pvn(aTHX_ namepv, namelen, SVt_PVAV)
#define pad_add_my_hash_pvn(namepv, namelen) \
    THX_pad_add_my_pvn(aTHX_ namepv, namelen, SVt_PVHV)

/*
 * parser pieces
 *
 * These functions reimplement fairly low-level parts of the Perl syntax,
 * using the character-level public lexer API.
 */

#define DEMAND_IMMEDIATE 0x00000001
#define DEMAND_NOCONSUME 0x00000002
#define demand_unichar(c, f) THX_demand_unichar(aTHX_ c, f)
static void THX_demand_unichar(pTHX_ I32 c, U32 flags)
{
    I32 next;
    char *buf;
    size_t i;

	if(!(flags & DEMAND_IMMEDIATE)) lex_read_space(0);
    next = lex_peek_unichar(0);
	if(next != c) {
        Newx(buf, strlen(PL_parser->bufptr), char);
        strcpy(buf, PL_parser->bufptr);
        for(i = strlen(buf); i > 0 ;i--) {
            if(buf[i] == '\n') { buf[i] = '\0'; break; }
        }
        croak("syntax error: expected '%s', but found '%s' at \"%s\"",
            (char *)&c, (char *)&next, buf );
    }
	if(!(flags & DEMAND_NOCONSUME)) lex_read_unichar(0);
}

#define parse_idword(prefix) THX_parse_idword(aTHX_ prefix)
static SV *THX_parse_idword(pTHX_ char const *prefix)
{
	STRLEN prefixlen, idlen;
	SV *sv;
	char *buf, *start, *s, c;
    size_t i;
	s = start = PL_parser->bufptr;
	c = *s;
	if(!isIDFIRST(c)) {
        Newx(buf, strlen(s), char);
        strcpy(buf, s);
        for(i = strlen(buf); i > 0 ;i--) {
            if(buf[i] == '\n') { buf[i] = '\0'; break; }
        }
        croak("syntax error: invalid identifier found at: \"%s\"", s);
    }
	do {
		c = *++s;
	} while(isALNUM(c));
	lex_read_to(s);
	prefixlen = strlen(prefix);
	idlen = s-start;
	sv = sv_2mortal(newSV(prefixlen + idlen));
	Copy(prefix, SvPVX(sv), prefixlen, char);
	Copy(start, SvPVX(sv)+prefixlen, idlen, char);
	SvPVX(sv)[prefixlen + idlen] = 0;
	SvCUR_set(sv, prefixlen + idlen);
	SvPOK_on(sv);
	return sv;
}

#define parse_varname(sigil) THX_parse_varname(aTHX_ sigil)
static SV *THX_parse_varname(pTHX_ const char *sigil)
{
	demand_unichar(sigil[0], DEMAND_IMMEDIATE);
	lex_read_space(0);
	return parse_idword(sigil);
}

#define parse_scalar_varname() THX_parse_varname(aTHX_ "$")
#define parse_array_varname()  THX_parse_varname(aTHX_ "@")
#define parse_hash_varname()   THX_parse_varname(aTHX_ "%")

/* end stolen from Scope::Escape::Sugar */

#define caller_package() THX_caller_package(aTHX)
static SV *THX_caller_package(pTHX)
{
    return sv_2mortal(newSVpv(HvNAME(PL_curstash), 0));
}

#define parse_metadata() THX_parse_metadata(aTHX)
static OP *THX_parse_metadata(pTHX)
{
    OP *metadata;

    demand_unichar('(', DEMAND_IMMEDIATE);
    metadata = parse_listexpr(0);
    lex_read_space(0);
    demand_unichar(')', 0);

    return metadata;
}

static OP *parse_class(pTHX_ GV *namegv, SV *psobj, U32 *flagsp)
{
    SV *caller = NULL, *class_name, *metadata, *class;
    CV *metadata_cv;
    OP *metadata_op, *local_class, *self_class_lexicals, *block;
    int floor;
    struct data *data;

    *flagsp |= CALLPARSER_STATEMENT;

    data = (struct data *)SvIVX(psobj);

    /* parse class name and package */
    lex_read_space(0);
    if (lex_peek_unichar(0) == ':') {
        demand_unichar(':', DEMAND_IMMEDIATE);
        demand_unichar(':', DEMAND_IMMEDIATE);
        caller = sv_2mortal(newSVpvs("main"));
    }
    class_name = parse_idword("");
    while (lex_peek_unichar(0) == ':') {
        demand_unichar(':', DEMAND_IMMEDIATE);
        demand_unichar(':', DEMAND_IMMEDIATE);
        if (caller) {
            sv_catpvs(caller, "::");
            sv_catsv(caller, class_name);
        }
        else {
            caller = class_name;
        }
        class_name = parse_idword("");
    }

    /* get caller */
    if (!caller) {
        caller = caller_package();
    }

    /* parse metadata */
    floor = start_subparse(0, CVf_ANON);
    /* apparently __PACKAGE__ looks at PL_curstash, but ->SUPER:: looks at
     * CopSTASH(PL_curcop) - no idea why they would be different here */
    CopSTASH_set(PL_curcop, PL_curstash);
    lex_read_space(0);
    if (lex_peek_unichar(0) == '(') {
        metadata_op = newANONHASH(parse_metadata());
    }
    else {
        metadata_op = newOP(OP_UNDEF, 0);
    }

    /* evaluate metadata at compile time */
    ENTER;
    {
        dSP;
        CV *metadata_cv;
        metadata_cv = newATTRSUB(floor, NULL, NULL, NULL, metadata_op);
        if (CvROOT(metadata_cv)) {
            PUSHMARK(SP);
            call_sv((SV*)metadata_cv, G_SCALAR|G_NOARGS);
            SPAGAIN;
            metadata = POPs;
            PUTBACK;
        }
        else {
            croak_sv(ERRSV);
        }
    }
    LEAVE;

    /* call mop::syntax::build_class with the name and metadata */
    ENTER;
    {
        dSP;
        char buf[128];
        PUSHMARK(SP);
        EXTEND(SP, 3);
        PUSHs(class_name);
        PUSHs(metadata);
        PUSHs(caller);
        PUTBACK;
        if (SvTRUE(data->indicator)) {
            snprintf(buf, 127, "%s::build_role", data->package);
            call_pv(buf, G_SCALAR);
        }
        else {
            snprintf(buf, 127, "%s::build_class", data->package);
            call_pv(buf, G_SCALAR);
        }
        SPAGAIN;
        class = POPs;
        PUTBACK;
    }
    LEAVE;

    /* localize $::CLASS to the class that we built */
    floor = start_subparse(0, 0);
    local_class = newASSIGNOP(0, op_lvalue(newUNOP(OP_RV2SV, 0, newGVOP(OP_GV, 0, gv_fetchpv("::CLASS", 0, SVt_PV))), OP_NULL), 0, newSVOP(OP_CONST, 0, newSVsv(class)));

    /* create $self and $class lexicals */
    {
        OP *var_self, *var_class;

        var_self = newOP(OP_PADSV, (OPpLVAL_INTRO << 8)|OPf_MOD);
        var_self->op_targ = pad_add_my_scalar_pvn("$self", 5);
        var_class = newOP(OP_PADSV, (OPpLVAL_INTRO << 8)|OPf_MOD);
        var_class->op_targ = pad_add_my_scalar_pvn("$class", 6);
        self_class_lexicals = newLISTOP(OP_LIST, 0, var_self, var_class);
    }

    /* parse the class block */
    demand_unichar('{', DEMAND_NOCONSUME);
    block = parse_block(0);

    /* stick localization and the lexicals on the front of the block */
    block = op_prepend_elem(OP_LINESEQ,
                            newSTATEOP(0, NULL, self_class_lexicals),
                            block);
    block = op_prepend_elem(OP_LINESEQ,
                            newSTATEOP(0, NULL, local_class),
                            block);

    /* evaluate the class block at compile time */
    ENTER;
    {
        dSP;
        CV *class_cv;
        class_cv = newATTRSUB(floor, NULL, NULL, NULL, block);
        if (CvROOT(class_cv)) {
            PUSHMARK(SP);
            call_sv((SV*)class_cv, G_VOID|G_NOARGS);
            PUTBACK;
        }
        else {
            croak_sv(ERRSV);
        }
    }
    LEAVE;

    /* finalize the class, still at compile time */
    ENTER;
    {
        dSP;
        char buf[128];
        PUSHMARK(SP);
        EXTEND(SP, 3);
        PUSHs(class_name);
        PUSHs(class);
        PUSHs(caller);
        PUTBACK;
        if (SvTRUE(data->indicator)) {
            snprintf(buf, 127, "%s::finalize_role", data->package);
            call_pv(buf, G_VOID);
        }
        else {
            snprintf(buf, 127, "%s::finalize_class", data->package);
            call_pv(buf, G_VOID);
        }
        PUTBACK;
    }
    LEAVE;

    /* the class keyword has no runtime component */
    return newOP(OP_NULL, 0);
}

static OP *check_class(pTHX_ OP *entersubop, GV *namegv, SV *ckobj)
{
    op_free(entersubop);
    return newOP(OP_NULL, 0);
}

static OP *parse_has(pTHX_ GV *namegv, SV *psobj, U32 *flagsp)
{
    SV *name;
    OP *ret, *pad_op, *metadata = NULL, *attr_default = NULL;
    I32 sigil;

    *flagsp |= CALLPARSER_STATEMENT;

    lex_read_space(0);
    sigil = lex_peek_unichar(0);
    if (sigil == '$') {
        name = parse_scalar_varname();
    }
    else if (sigil == '@') {
        name = parse_array_varname();
    }
    else if (sigil == '%') {
        name = parse_hash_varname();
    }
    else {
        char *buf;
        STRLEN q;

        Newx(buf, strlen(PL_parser->bufptr), char);
        strcpy(buf, PL_parser->bufptr);
        for(q = strlen(buf); q > 0 ; q--) {
            if(buf[q] == '\n') { buf[q] = '\0'; break; }
        }

        croak("syntax error: expected valid sigil, but found '%c' at \"%s\"", (char)sigil, buf);
    }

    lex_read_space(0);
    if (lex_peek_unichar(0) == '(') {
        metadata = newANONHASH(parse_metadata());
    }

    lex_read_space(0);
    if (lex_peek_unichar(0) != ';') {
        I32 floor;

        demand_unichar('=', 0);
        lex_read_space(0);
        floor = start_subparse(0, CVf_ANON);
        attr_default = newANONSUB(floor, NULL, parse_arithexpr(0));
    }

    if (sigil == '$') {
        pad_op = newOP(OP_PADSV, 0);
        pad_op->op_targ = pad_add_my_scalar_sv(name);
    }
    else if (sigil == '@') {
        pad_op = newOP(OP_PADAV, 0);
        pad_op->op_targ = pad_add_my_array_sv(name);
    }
    else if (sigil == '%') {
        pad_op = newOP(OP_PADHV, 0);
        pad_op->op_targ = pad_add_my_hash_sv(name);
    }
    else {
        croak("weird sigil '%c'???", sigil);
    }

    pad_op = Perl_localize(aTHX_ pad_op, 1);

    SvREFCNT_inc_simple_void_NN(name);
    ret = newLISTOP(OP_LIST, 0,
                    newSVOP(OP_CONST, 0, name),
                    newANONLIST(pad_op));

    if (metadata) {
        op_append_elem(OP_LIST, ret, metadata);
    }
    else {
        op_append_elem(OP_LIST, ret, newOP(OP_UNDEF, 0));
    }

    if (attr_default) {
        op_append_elem(OP_LIST, ret, attr_default);
    }

    return ret;
}

#define parse_parameter_default(i, padoffset) THX_parse_parameter_default(aTHX_ i, padoffset)
static OP *THX_parse_parameter_default(pTHX_ IV i, PADOFFSET padoffset)
{
    SV *name;
    OP *default_expr, *check_args, *get_var, *assign_default;
    char sigil;

    lex_read_space(0);

    default_expr = parse_arithexpr(0);

    check_args = newBINOP(OP_LE, 0, newUNOP(OP_RV2AV, 0, newGVOP(OP_GV, 0, gv_fetchpv("_", 0, SVt_PVAV))), newSVOP(OP_CONST, 0, newSViv(i)));

    name = newSVsv(*av_fetch(PL_comppad_name, padoffset, 0));
    sigil = SvPVX(name)[0];
    if (sigil == '$') {
        get_var = newOP(OP_PADSV, 0);
    }
    else if (sigil == '@') {
        get_var = newOP(OP_PADAV, 0);
    }
    else if (sigil == '%') {
        get_var = newOP(OP_PADHV, 0);
    }
    else {
        croak("weird pad entry '%s'", name);
    }
    get_var->op_targ = padoffset;
    assign_default = newASSIGNOP(OPf_STACKED, get_var, 0, default_expr);

    return newLOGOP(OP_AND, 0, check_args, assign_default);
}

#define parse_method_prototype() THX_parse_method_prototype(aTHX)
static OP *THX_parse_method_prototype(pTHX)
{
    OP *myvars, *defaults, *get_args, *arg_assign;
    IV i = 0;

    demand_unichar('(', DEMAND_IMMEDIATE);

    lex_read_space(0);
    if (lex_peek_unichar(0) == ')') {
        lex_read_unichar(0);
        return NULL;
    }

    myvars = newLISTOP(OP_LIST, 0, NULL, NULL);
    defaults = newLISTOP(OP_LINESEQ, 0, NULL, NULL);

    for (;;) {
        OP *pad_op;
        I32 next;
        I32 type;
        SV *name;
        char *buf;
        size_t q;

        lex_read_space(0);
        next = lex_peek_unichar(0);
        if (next == '$') {
            pad_op = newOP(OP_PADSV, 0);
            name = parse_scalar_varname();
            pad_op->op_targ = pad_add_my_scalar_sv(name);
        }
        else if (next == '@') {
            pad_op = newOP(OP_PADAV, 0);
            name = parse_array_varname();
            pad_op->op_targ = pad_add_my_array_sv(name);
        }
        else if (next == '%') {
            pad_op = newOP(OP_PADHV, 0);
            name = parse_hash_varname();
            pad_op->op_targ = pad_add_my_hash_sv(name);
        }
        else {
            Newx(buf, strlen(PL_parser->bufptr), char);
            strcpy(buf, PL_parser->bufptr);
            for(q = strlen(buf); q > 0 ; q--) {
                if(buf[q] == '\n') { buf[q] = '\0'; break; }
            }
            croak("syntax error: expected valid sigil, but found '%c' at \"%s\"", (char)next, buf);
        }

        op_append_elem(OP_LIST, myvars, pad_op);

        lex_read_space(0);
        next = lex_peek_unichar(0);

        if (next == '=') {
            OP *set_default;

            lex_read_unichar(0);
            set_default = parse_parameter_default(i, pad_op->op_targ);
            op_append_elem(OP_LINESEQ,
                           defaults,
                           newSTATEOP(0, NULL, set_default));

            lex_read_space(0);
            next = lex_peek_unichar(0);
        }

        i++;

        if (next == ',') {
            lex_read_unichar(0);
        }
        else if (next == ')') {
            lex_read_unichar(0);
            break;
        }
        else {
            Newx(buf, strlen(PL_parser->bufptr), char);
            strcpy(buf, PL_parser->bufptr);
            for(q = strlen(buf); q > 0 ; q--) {
                if(buf[q] == '\n') { buf[q] = '\0'; break; }
            }
            croak("syntax error: expected comma or closing parenthesis, but found '%s' at \"%s\"", (char *)&next, buf);
        }
    }

    myvars = Perl_localize(aTHX_ myvars, 1);
    myvars = Perl_sawparens(aTHX_ myvars);

    get_args = newUNOP(OP_RV2AV, 0, newGVOP(OP_GV, 0, gv_fetchpv("_", 0, SVt_PVAV)));
    arg_assign = newASSIGNOP(OPf_STACKED, myvars, 0, get_args);

    return op_prepend_elem(OP_LINESEQ,
                           newSTATEOP(0, NULL, arg_assign),
                           defaults);
}

static OP *parse_method(pTHX_ GV *namegv, SV *psobj, U32 *flagsp)
{
    I32 floor;
    SV *method_name = NULL;
    OP *arg_assign = NULL, *block, *code = NULL;

    *flagsp |= CALLPARSER_STATEMENT;

    floor = start_subparse(0, CVf_ANON);

    if (SvTRUE(psobj)) {
        lex_read_space(0);
        method_name = parse_idword("");
    }

    lex_read_space(0);
    if (lex_peek_unichar(0) == '(') {
        arg_assign = parse_method_prototype();
    }

    lex_read_space(0);
    if (lex_peek_unichar(0) == '{') {
        block = parse_block(0);

        if (arg_assign) {
            block = op_prepend_elem(OP_LINESEQ,
                                    newSTATEOP(0, NULL, arg_assign),
                                    block);
        }

        code = newANONSUB(floor, NULL, block);
    }
    else {
        newANONSUB(floor, NULL, newOP(OP_NULL, 0));
    }

    if (SvTRUE(psobj)) {
        SvREFCNT_inc_simple_void_NN(method_name);
        return newLISTOP(OP_LIST, 0,
                         newSVOP(OP_CONST, 0, method_name),
                         code);
    }
    else {
        return code;
    }
}

MODULE = mop  PACKAGE = mop::internal::instance

PROTOTYPES: DISABLE

SV *
create_instance(SV *class, SV *slots_ref)
  PREINIT:
    struct mop_instance *instance;
    AV *slot_names;
    HV *slots;
    HE *slot_entry;
    SV *instance_sv;
  CODE:
    instance = allocate_mop_instance(class);

    if (!slots_ref || !SvOK(slots_ref)) {
        slots_ref = sv_2mortal(newRV_noinc((SV *)newHV()));
    }
    slots = (HV *)SvRV(slots_ref);

    slot_names = get_slot_names(class);

    hv_iterinit(slots);
    while (slot_entry = hv_iternext(slots)) {
        I32 offset;

        offset = slot_offset_for_name(slot_names, HeSVKEY_force(slot_entry));
        mop_set_slot_at(instance, offset, HeVAL(slot_entry));
    }

    instance_sv = newSViv((IV)instance);

    sv_magicext(instance_sv, NULL, PERL_MAGIC_ext, &vtbl_instance, NULL, 0);

    RETVAL = newRV_noinc(instance_sv);
  OUTPUT:
    RETVAL

SV *
get_class(SV *instance_ref)
  PREINIT:
    struct mop_instance *instance;
  CODE:
    instance = (struct mop_instance *)SvIVX(SvRV(instance_ref));
    RETVAL = SvREFCNT_inc(mop_get_class(instance));
  OUTPUT:
    RETVAL

void
set_class(SV *instance_ref, SV *class)
  PREINIT:
    struct mop_instance *instance;
  CODE:
    instance = (struct mop_instance *)SvIVX(SvRV(instance_ref));
    mop_set_class(instance, class);

SV *
get_uuid(SV *instance_ref)
  PREINIT:
    struct mop_instance *instance;
    I32 *uuid;
  CODE:
    instance = (struct mop_instance *)SvIVX(SvRV(instance_ref));
    uuid = mop_get_uuid(instance);
    RETVAL = uuid_as_string(uuid);
  OUTPUT:
    RETVAL

SV *
get_slots(SV *instance_ref)
  PREINIT:
    struct mop_instance *instance;
    AV *slot_names;
    SV **slot_vals;
    I32 number_of_slots;
    HV *slots;
    int i;
  CODE:
    instance = (struct mop_instance *)SvIVX(SvRV(instance_ref));
    slot_names = get_slot_names(mop_get_class(instance));
    slot_vals = mop_get_slots(instance);
    number_of_slots = av_len(slot_names) + 1;
    slots = newHV();
    for (i = 0; i < number_of_slots; ++i) {
        SV **key;

        key = av_fetch(slot_names, i, 0);
        if (key) {
            hv_store_ent(slots, *key, newRV_inc(slot_vals[i]), 0);
        }
    }
    RETVAL = newRV_noinc((SV *)slots);
  OUTPUT:
    RETVAL

SV *
get_slot_at(SV *instance_ref, SV *slot)
  PREINIT:
    struct mop_instance *instance;
    AV *slot_names;
    I32 offset;
    SV *value;
  CODE:
    instance = (struct mop_instance *)SvIVX(SvRV(instance_ref));
    slot_names = get_slot_names(mop_get_class(instance));
    offset = slot_offset_for_name(slot_names, slot);
    value = mop_get_slot_at(instance, offset);
    if (value && (SvOK(value) || SvTYPE(value) == SVt_PVAV || SvTYPE(value) == SVt_PVHV)) {
        RETVAL = newRV_inc(value);
    }
    else {
        char sigil;

        sigil = (SvPV_nolen(slot))[0];
        switch (sigil) {
        case '$':
            RETVAL = newRV_noinc(newSV(0));
            break;
        case '@':
            RETVAL = newRV_noinc((SV *)newAV());
            break;
        case '%':
            RETVAL = newRV_noinc((SV *)newHV());
            break;
        default:
            croak("unknown sigil: %c", sigil);
        }
    }
  OUTPUT:
    RETVAL

void
set_slot_at(SV *instance_ref, SV *slot, SV *value)
  PREINIT:
    struct mop_instance *instance;
    AV *slot_names;
    I32 offset;
  CODE:
    if (!value || !SvOK(value)) {
        char sigil;

        sigil = (SvPV_nolen(slot))[0];
        switch (sigil) {
        case '$':
            value = sv_2mortal(newRV_noinc(newSV(0)));
            break;
        case '@':
            value = sv_2mortal(newRV_noinc((SV *)newAV()));
            break;
        case '%':
            value = sv_2mortal(newRV_noinc((SV *)newHV()));
            break;
        default:
            croak("unknown sigil: %c", sigil);
        }
    }
    instance = (struct mop_instance *)SvIVX(SvRV(instance_ref));
    slot_names = get_slot_names(mop_get_class(instance));
    offset = slot_offset_for_name(slot_names, slot);
    mop_set_slot_at(instance, offset, value);

void
_set_offset_map(SV *class, SV *offsets)
  CODE:
    attach_slot_names(SvRV(class), (AV *)SvRV(offsets));

MODULE = mop  PACKAGE = mop::parser

PROTOTYPES: DISABLE

void
init_parser_for(package)
    const char *package
  PREINIT:
    char buf[128];
    char *package_copy;
    struct data *data;
    SV *psobj;
  CODE:
    package_copy = strdup(package);

    snprintf(buf, 127, "%s::class", package);
    data = malloc(sizeof(struct data));
    data->indicator = &PL_sv_no;
    data->package   = package_copy;
    psobj = newSViv((IV)data);
    cv_set_call_parser(get_cv(buf, 0), parse_class, psobj);
    cv_set_call_checker(get_cv(buf, 0), check_class, &PL_sv_undef);

    snprintf(buf, 127, "%s::role", package);
    data = malloc(sizeof(struct data));
    data->indicator = &PL_sv_yes;
    data->package   = package_copy;
    psobj = newSViv((IV)data);
    cv_set_call_parser(get_cv(buf, 0), parse_class, psobj);
    cv_set_call_checker(get_cv(buf, 0), check_class, &PL_sv_undef);

    snprintf(buf, 127, "%s::has", package);
    cv_set_call_parser(get_cv(buf, 0), parse_has, &PL_sv_undef);

    snprintf(buf, 127, "%s::method", package);
    cv_set_call_parser(get_cv(buf, 0), parse_method, &PL_sv_yes);

    snprintf(buf, 127, "%s::BUILD", package);
    cv_set_call_parser(get_cv(buf, 0), parse_method, &PL_sv_no);

    snprintf(buf, 127, "%s::DEMOLISH", package);
    cv_set_call_parser(get_cv(buf, 0), parse_method, &PL_sv_no);
