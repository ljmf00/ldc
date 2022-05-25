
/* Compiler implementation of the D programming language
 * Copyright (C) 1999-2022 by The D Language Foundation, All Rights Reserved
 * written by Walter Bright
 * https://www.digitalmars.com
 * Distributed under the Boost Software License, Version 1.0.
 * https://www.boost.org/LICENSE_1_0.txt
 * https://github.com/dlang/dmd/blob/master/src/dmd/cond.h
 */

#pragma once

#include "ast_node.h"
#include "globals.h"
#include "visitor.h"

class Expression;
class Identifier;
class Module;
struct Scope;
class DebugCondition;
class ForeachStatement;
class ForeachRangeStatement;

enum Include
{
    INCLUDEnotComputed, /// not computed yet
    INCLUDEyes,         /// include the conditional code
    INCLUDEno           /// do not include the conditional code
};

class Condition : public ASTNode
{
public:
    Loc loc;
    Include inc;

    DYNCAST dyncast() const override { return DYNCAST_CONDITION; }

    virtual Condition *syntaxCopy() = 0;
    virtual int include(Scope *sc) = 0;
    virtual DebugCondition *isDebugCondition() { return NULL; }
    virtual VersionCondition *isVersionCondition() { return NULL; }
    void accept(Visitor *v) override { v->visit(this); }
};

class StaticForeach
{
public:
    Loc loc;

    ForeachStatement *aggrfe;
    ForeachRangeStatement *rangefe;

    bool needExpansion;

    StaticForeach *syntaxCopy();
};

class DVCondition : public Condition
{
public:
    unsigned level;
    Identifier *ident;
    Module *mod;

    DVCondition *syntaxCopy() override;
    void accept(Visitor *v) override { v->visit(this); }
};

class DebugCondition : public DVCondition
{
public:
    static void addGlobalIdent(const char *ident);

    int include(Scope *sc) override;
    DebugCondition *isDebugCondition() override { return this; }
    void accept(Visitor *v) override { v->visit(this); }
};

class VersionCondition : public DVCondition
{
public:
    static void addGlobalIdent(const char *ident);
    static void addPredefinedGlobalIdent(const char *ident);

    int include(Scope *sc) override;
    VersionCondition *isVersionCondition() override { return this; }
    void accept(Visitor *v) override { v->visit(this); }
};

class StaticIfCondition : public Condition
{
public:
    Expression *exp;

    StaticIfCondition *syntaxCopy() override;
    int include(Scope *sc) override;
    void accept(Visitor *v) override { v->visit(this); }
};
