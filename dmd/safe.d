/**
 * Checks whether member access or array casting is allowed in `@safe` code.
 *
 * Specification: $(LINK2 https://dlang.org/spec/function.html#function-safety, Function Safety)
 *
 * Copyright:   Copyright (C) 1999-2021 by The D Language Foundation, All Rights Reserved
 * Authors:     $(LINK2 http://www.digitalmars.com, Walter Bright)
 * License:     $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 * Source:      $(LINK2 https://github.com/dlang/dmd/blob/master/src/dmd/safe.d, _safe.d)
 * Documentation:  https://dlang.org/phobos/dmd_safe.html
 * Coverage:    https://codecov.io/gh/dlang/dmd/src/master/src/dmd/safe.d
 */

module dmd.safe;

import core.stdc.stdio;

import dmd.aggregate;
import dmd.astenums;
import dmd.dclass;
import dmd.declaration;
import dmd.dscope;
import dmd.expression;
import dmd.id;
import dmd.identifier;
import dmd.mtype;
import dmd.target;
import dmd.tokens;


/*************************************************************
 * Check for unsafe access in @safe code:
 * 1. read overlapped pointers
 * 2. write misaligned pointers
 * 3. write overlapped storage classes
 * Print error if unsafe.
 * Params:
 *      sc = scope
 *      e = expression to check
 *      readonly = if access is read-only
 *      printmsg = print error message if true
 * Returns:
 *      true if error
 */

bool checkUnsafeAccess(Scope* sc, Expression e, bool readonly, bool printmsg)
{
    //printf("checkUnsafeAccess(e: '%s', readonly: %d, printmsg: %d)\n", e.toChars(), readonly, printmsg);
    if (e.op != TOK.dotVariable)
        return false;
    DotVarExp dve = cast(DotVarExp)e;
    if (VarDeclaration v = dve.var.isVarDeclaration())
    {
        if (sc.intypeof || !sc.func || !sc.func.isSafeBypassingInference())
            return false;
        auto ad = v.toParent2().isAggregateDeclaration();
        if (!ad)
            return false;

        // needed to set v.overlapped and v.overlapUnsafe
        if (ad.sizeok != Sizeok.done)
            ad.determineSize(ad.loc);

        const hasPointers = v.type.hasPointers();
        if (hasPointers)
        {
            if (v.overlapped && sc.func.setUnsafe())
            {
                if (printmsg)
                    e.error("field `%s.%s` cannot access pointers in `@safe` code that overlap other fields",
                        ad.toChars(), v.toChars());
                return true;
            }
        }

        if (v.type.hasInvariant())
        {
            if (v.overlapped && sc.func.setUnsafe())
            {
                if (printmsg)
                    e.error("field `%s.%s` cannot access structs with invariants in `@safe` code that overlap other fields",
                        ad.toChars(), v.toChars());
                return true;
            }
        }

        if (readonly || !e.type.isMutable())
            return false;

        if (hasPointers && v.type.toBasetype().ty != Tstruct)
        {
            if ((!ad.type.alignment.isDefault() && ad.type.alignment.get() < target.ptrsize ||
                 (v.offset & (target.ptrsize - 1))) &&
                sc.func.setUnsafe())
            {
                if (printmsg)
                    e.error("field `%s.%s` cannot modify misaligned pointers in `@safe` code",
                        ad.toChars(), v.toChars());
                return true;
            }
        }

        if (v.overlapUnsafe && sc.func.setUnsafe())
        {
             if (printmsg)
                 e.error("field `%s.%s` cannot modify fields in `@safe` code that overlap fields with other storage classes",
                    ad.toChars(), v.toChars());
             return true;
        }
    }
    return false;
}


/**********************************************
 * Determine if it is @safe to cast e from tfrom to tto.
 * Params:
 *      e = expression to be cast
 *      tfrom = type of e
 *      tto = type to cast e to
 * Returns:
 *      true if @safe
 */
bool isSafeCast(Expression e, Type tfrom, Type tto)
{
    // Implicit conversions are always safe
    if (tfrom.implicitConvTo(tto))
        return true;

    if (!tto.hasPointers())
        return true;

    auto tfromb = tfrom.toBasetype();
    auto ttob = tto.toBasetype();

    if (ttob.ty == Tclass && tfromb.ty == Tclass)
    {
        ClassDeclaration cdfrom = tfromb.isClassHandle();
        ClassDeclaration cdto = ttob.isClassHandle();

        int offset;
        if (!cdfrom.isBaseOf(cdto, &offset) &&
            !((cdfrom.isInterfaceDeclaration() || cdto.isInterfaceDeclaration())
                && cdfrom.classKind == ClassKind.d && cdto.classKind == ClassKind.d))
            return false;

        if (cdfrom.isCPPinterface() || cdto.isCPPinterface())
            return false;

        if (!MODimplicitConv(tfromb.mod, ttob.mod))
            return false;
        return true;
    }

    if (ttob.ty == Tarray && tfromb.ty == Tsarray) // https://issues.dlang.org/show_bug.cgi?id=12502
        tfromb = tfromb.nextOf().arrayOf();

    if (ttob.ty == Tarray   && tfromb.ty == Tarray ||
        ttob.ty == Tpointer && tfromb.ty == Tpointer)
    {
        Type ttobn = ttob.nextOf().toBasetype();
        Type tfromn = tfromb.nextOf().toBasetype();

        /* From void[] to anything mutable is unsafe because:
         *  int*[] api;
         *  void[] av = api;
         *  int[] ai = cast(int[]) av;
         *  ai[0] = 7;
         *  *api[0] crash!
         */
        if (tfromn.ty == Tvoid && ttobn.isMutable())
        {
            if (ttob.ty == Tarray && e.op == TOK.arrayLiteral)
                return true;
            return false;
        }

        // If the struct is opaque we don't know about the struct members then the cast becomes unsafe
        if (ttobn.ty == Tstruct && !(cast(TypeStruct)ttobn).sym.members ||
            tfromn.ty == Tstruct && !(cast(TypeStruct)tfromn).sym.members)
            return false;

        const frompointers = tfromn.hasPointers();
        const topointers = ttobn.hasPointers();

        if (frompointers && !topointers && ttobn.isMutable())
            return false;

        if (!frompointers && topointers)
            return false;

        if (!topointers &&
            ttobn.ty != Tfunction && tfromn.ty != Tfunction &&
            (ttob.ty == Tarray || ttobn.size() <= tfromn.size()) &&
            MODimplicitConv(tfromn.mod, ttobn.mod))
        {
            return true;
        }
    }
    return false;
}

/*************************************************
 * Check for unsafe use of `.ptr` or `.funcptr`
 * Params:
 *      sc = context
 *      e = expression for error messages
 *      id = `ptr` or `funcptr`
 *      flag = DotExpFlag
 * Returns:
 *      true if error
 */
bool checkUnsafeDotExp(Scope* sc, Expression e, Identifier id, int flag)
{
    if (!(flag & DotExpFlag.noDeref) && // this use is attempting a dereference
        sc.func &&                      // inside a function
        !sc.intypeof &&                 // allow unsafe code in typeof expressions
        !(sc.flags & SCOPE.debug_) &&   // allow unsafe code in debug statements
        sc.func.setUnsafe())            // infer this function to be unsafe
    {
        if (id == Id.ptr)
            e.error("`%s.ptr` cannot be used in `@safe` code, use `&%s[0]` instead", e.toChars(), e.toChars());
        else
            e.error("`%s.%s` cannot be used in `@safe` code", e.toChars(), id.toChars());
        return true;
    }
    return false;
}
