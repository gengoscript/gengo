const std = @import("std");
const chunk = @import("chunk.zig");
const common = @import("common.zig");
const heap = @import("../runtime/heap.zig");
const lexer_mod = @import("lexer.zig");
const op_mod = @import("op.zig");
const token = @import("token.zig");
const value_mod = @import("value.zig");

const Lexer = lexer_mod.Lexer;
const FieldTypeAlt = value_mod.FieldTypeAlt;
const FieldTypeSpec = value_mod.FieldTypeSpec;
const Op = op_mod.Op;
const FieldTypeTag = value_mod.FieldTypeTag;
const StructFieldSpec = value_mod.StructFieldSpec;
const TT = token.TT;
const Token = token.Token;
const Object = value_mod.Object;
const StructTypeObj = value_mod.StructTypeObj;
const Value = value_mod.Value;

const MaxLocals = 64;
const MaxScopes = 8;
const MaxLoopDepth = 16;
const MaxLoopBreaks = 128;
const MaxTypeAlts = 8;
const MaxStructTypes = 128;
const MaxSwitchJumps = 256;
const MaxUpvalues = 64;

const Prec = enum(u8) {
    none,
    assign,
    or_,
    and_,
    eq_,
    bit_or,
    bit_xor,
    bit_and,
    shift,
    cmp,
    term,
    factor,
    unary,
    call,
    primary,
    fn next(self: Prec) Prec {
        return @enumFromInt(@intFromEnum(self) + 1);
    }
};

const Local = struct { name: []const u8 };
const Upvalue = struct { name: []const u8, index: u8, from_upvalue: bool };
const FuncInfo = struct {
    locals: [MaxLocals]Local = undefined,
    local_count: u8 = 0,
    upvalues: [MaxUpvalues]Upvalue = undefined,
    upvalue_count: u8 = 0,
};

const LoopCtx = struct {
    continue_target: usize,
    local_keep: u8,
    break_offsets: [MaxLoopBreaks]usize = undefined,
    break_count: usize = 0,
};

const StructTypeInfo = struct {
    name: []const u8,
};

const AssignTargetStep = union(enum) {
    dot_name: []const u8,
    index_number: f64,
    index_string: []const u8,
};

const AssignTarget = struct {
    root: Token,
    step_start: u16,
    step_count: u8,
};
const MultiAssignValueScratch = "__gengo_tmp_value";

pub const Compiler = struct {
    lex: Lexer,
    prev: Token = undefined,
    cur: Token = undefined,
    scopes: [MaxScopes]FuncInfo = undefined,
    scope_depth: u8 = 0,
    loops: [MaxLoopDepth]LoopCtx = undefined,
    loop_depth: u8 = 0,
    struct_types: [MaxStructTypes]StructTypeInfo = undefined,
    struct_type_count: usize = 0,

    pub fn init(src: []const u8) Compiler {
        return .{ .lex = .{ .src = src } };
    }

    pub fn compile(self: *Compiler) !void {
        chunk.reset();
        self.struct_type_count = 0;
        self.advance();
        while (!self.check(.eof)) try self.decl();
        try chunk.emitOp(.halt, self.prev.line);
    }

    fn hasStructType(self: *Compiler, name: []const u8) bool {
        var i: usize = 0;
        while (i < self.struct_type_count) : (i += 1) {
            if (common.streq(self.struct_types[i].name, name)) return true;
        }
        return false;
    }

    fn addStructType(self: *Compiler, name: []const u8) !void {
        if (self.hasStructType(name)) return error.DuplicateStructType;
        if (self.struct_type_count >= MaxStructTypes) return error.TooManyStructTypes;
        self.struct_types[self.struct_type_count] = .{ .name = name };
        self.struct_type_count += 1;
    }

    fn inFunc(self: *Compiler) bool {
        return self.scope_depth > 0;
    }

    fn currentScope(self: *Compiler) *FuncInfo {
        return &self.scopes[self.scope_depth - 1];
    }

    fn resolveLocal(self: *Compiler, name: []const u8) ?u8 {
        if (!self.inFunc()) return null;
        const scope = self.currentScope();
        var i: u8 = scope.local_count;
        while (i > 0) {
            i -= 1;
            if (common.streq(scope.locals[i].name, name)) return i;
        }
        return null;
    }

    fn defineLocal(self: *Compiler, name: []const u8) !u8 {
        const scope = self.currentScope();
        if (scope.local_count >= MaxLocals) return error.TooManyLocals;
        const slot = scope.local_count;
        scope.locals[slot] = .{ .name = name };
        scope.local_count += 1;
        return slot;
    }

    fn emitGetVar(self: *Compiler, name: Token) !void {
        if (self.resolveLocal(name.src)) |slot| {
            try chunk.emit2(@intFromEnum(Op.get_local), slot, name.line);
        } else if (self.resolveUpvalue(name.src)) |uv| {
            try chunk.emit2(@intFromEnum(Op.get_upvalue), uv, name.line);
        } else {
            const idx = try chunk.addConst(.{ .string = name.src });
            try chunk.emit2(@intFromEnum(Op.get_global), idx, name.line);
        }
    }

    fn emitSetVar(self: *Compiler, name: Token) !void {
        if (self.resolveLocal(name.src)) |slot| {
            try chunk.emit2(@intFromEnum(Op.set_local), slot, name.line);
        } else if (self.resolveUpvalue(name.src)) |uv| {
            try chunk.emit2(@intFromEnum(Op.set_upvalue), uv, name.line);
        } else {
            const idx = try chunk.addConst(.{ .string = name.src });
            try chunk.emit2(@intFromEnum(Op.set_global), idx, name.line);
        }
    }

    fn resolveUpvalue(self: *Compiler, name: []const u8) ?u8 {
        if (self.scope_depth < 2) return null;
        return self.resolveUpvalueForScope(self.scope_depth - 1, name);
    }

    fn addUpvalueToScope(self: *Compiler, scope_index: u8, name: []const u8, index: u8, from_upvalue: bool) ?u8 {
        const scope = &self.scopes[scope_index];
        var u: u8 = 0;
        while (u < scope.upvalue_count) : (u += 1) {
            if (common.streq(scope.upvalues[u].name, name) and scope.upvalues[u].index == index and scope.upvalues[u].from_upvalue == from_upvalue) return u;
        }
        if (scope.upvalue_count >= MaxUpvalues) return null;
        const idx = scope.upvalue_count;
        scope.upvalues[idx] = .{ .name = name, .index = index, .from_upvalue = from_upvalue };
        scope.upvalue_count += 1;
        return idx;
    }

    // scope_index is the function scope that wants to capture `name` from its enclosing scope.
    fn resolveUpvalueForScope(self: *Compiler, scope_index: u8, name: []const u8) ?u8 {
        if (scope_index == 0) return null;
        const enclosing_index: u8 = scope_index - 1;
        const enclosing = &self.scopes[enclosing_index];

        var i: u8 = enclosing.local_count;
        while (i > 0) {
            i -= 1;
            if (common.streq(enclosing.locals[i].name, name)) {
                return self.addUpvalueToScope(scope_index, name, i, false);
            }
        }

        if (enclosing_index == 0) return null;
        const parent_up = self.resolveUpvalueForScope(enclosing_index, name) orelse return null;
        return self.addUpvalueToScope(scope_index, name, parent_up, true);
    }

    fn cleanupLocals(self: *Compiler, base: u8, line: u32) !void {
        if (!self.inFunc()) return;
        const scope = self.currentScope();
        while (scope.local_count > base) {
            try chunk.emitOp(.pop, line);
            scope.local_count -= 1;
        }
    }

    fn loopKeepBase(self: *Compiler) u8 {
        if (!self.inFunc()) return 0;
        return self.currentScope().local_count;
    }

    fn pushLoop(self: *Compiler, continue_target: usize, local_keep: u8) !void {
        if (self.loop_depth >= MaxLoopDepth) return error.TooManyNestedLoops;
        self.loops[self.loop_depth] = .{
            .continue_target = continue_target,
            .local_keep = local_keep,
        };
        self.loop_depth += 1;
    }

    fn popLoop(self: *Compiler) LoopCtx {
        self.loop_depth -= 1;
        return self.loops[self.loop_depth];
    }

    fn currentLoop(self: *Compiler) *LoopCtx {
        return &self.loops[self.loop_depth - 1];
    }

    fn emitBreak(self: *Compiler, line: u32) !void {
        if (self.loop_depth == 0) return error.BreakOutsideLoop;
        const loop = self.currentLoop();
        try self.cleanupLocals(loop.local_keep, line);
        const off = try chunk.emitJump(.jump, line);
        if (loop.break_count >= MaxLoopBreaks) return error.TooManyBreaksInLoop;
        loop.break_offsets[loop.break_count] = off;
        loop.break_count += 1;
    }

    fn emitContinue(self: *Compiler, line: u32) !void {
        if (self.loop_depth == 0) return error.ContinueOutsideLoop;
        const loop = self.currentLoop();
        try self.cleanupLocals(loop.local_keep, line);
        try chunk.emitLoop(loop.continue_target, line);
    }

    fn decl(self: *Compiler) anyerror!void {
        if (self.check(.ident) and self.peekTT() == .colon_eq) {
            try self.varDecl();
        } else if (self.check(.kw_struct)) {
            try self.structDecl();
        } else if (self.check(.kw_func) and self.isMethodDecl()) {
            try self.methodDecl();
        } else if (self.check(.kw_func) and self.isNamedFuncDecl()) {
            try self.namedFuncDecl();
        } else {
            try self.stmt();
        }
    }

    fn isMethodDecl(self: *Compiler) bool {
        var lx = self.lex;
        const t1 = lx.next();
        if (t1.typ != .lparen) return false;
        const t2 = lx.next();
        if (t2.typ != .ident) return false;
        const t3 = lx.next();
        if (t3.typ != .ident) return false;
        const t4 = lx.next();
        if (t4.typ != .rparen) return false;
        const t5 = lx.next();
        if (t5.typ != .ident) return false;
        const t6 = lx.next();
        return t6.typ == .lparen;
    }

    fn structDecl(self: *Compiler) !void {
        const kw = self.cur;
        self.advance(); // struct
        if (self.cur.typ != .ident) return error.UnexpectedToken;
        const name = self.cur;
        try self.addStructType(name.src);
        self.advance(); // name
        try self.consume(.lbrace);

        var field_specs: [MaxLocals]StructFieldSpec = undefined;
        var count: u8 = 0;
        if (!self.check(.rbrace)) {
            while (true) {
                if (self.cur.typ != .ident) return error.UnexpectedToken;
                if (count >= MaxLocals) return error.TooManyFields;
                const fname = self.cur.src;
                var i: u8 = 0;
                while (i < count) : (i += 1) {
                    if (common.streq(field_specs[i].name, fname)) return error.DuplicateField;
                }
                self.advance();

                var spec = StructFieldSpec{ .name = fname, .typ = .{ .alts = &[_]FieldTypeAlt{} } };
                if (self.match(.colon)) {
                    spec.typ = try self.parseFieldTypeSpec();
                    var ti: usize = 0;
                    while (ti < spec.typ.alts.len) : (ti += 1) {
                        const alt = spec.typ.alts[ti];
                        if (alt.typ == .struct_t) {
                            // Policy: no forward refs and no self refs.
                            if (common.streq(alt.struct_name, name.src)) return error.UnknownStructType;
                            if (!self.hasStructType(alt.struct_name)) return error.UnknownStructType;
                        }
                    }
                } else {
                    const alts = heap.bump(FieldTypeAlt, 1) orelse return error.OutOfMemory;
                    alts[0] = .{ .typ = .any };
                    spec.typ = .{ .alts = alts[0..1] };
                }

                field_specs[count] = spec;
                count += 1;
                if (!self.match(.comma)) break;
            }
        }
        try self.consume(.rbrace);

        const fields = heap.bump(StructFieldSpec, count) orelse return error.OutOfMemory;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            fields[i] = field_specs[i];
        }
        const st = heap.allocObject() orelse return error.OutOfMemory;
        st.* = .{ .struct_type = StructTypeObj{ .name = name.src, .fields = fields[0..count] } };
        try chunk.emitConst(.{ .object = st }, kw.line);

        if (self.inFunc()) {
            _ = try self.defineLocal(name.src);
        } else {
            const idx = try chunk.addConst(.{ .string = name.src });
            try chunk.emit2(@intFromEnum(Op.def_global), idx, kw.line);
        }
        self.matchOpt(.semicolon);
    }

    fn parseFieldTypeSpec(self: *Compiler) !FieldTypeSpec {
        var tmp: [MaxTypeAlts]FieldTypeAlt = undefined;
        var count: u8 = 0;

        if (self.match(.question)) {
            if (count >= MaxTypeAlts) return error.TooManyTypeAlternatives;
            tmp[count] = .{ .typ = .null_t };
            count += 1;
        }

        while (true) {
            if (self.cur.typ != .ident) return error.UnexpectedToken;
            const tname = self.cur.src;
            self.advance();

            var alt: FieldTypeAlt = .{ .typ = .struct_t, .struct_name = tname };
            if (common.streq(tname, "int")) {
                alt = .{ .typ = .int };
            } else if (common.streq(tname, "float")) {
                alt = .{ .typ = .float };
            } else if (common.streq(tname, "rune")) {
                alt = .{ .typ = .rune_t };
            } else if (common.streq(tname, "bool")) {
                alt = .{ .typ = .boolean };
            } else if (common.streq(tname, "string")) {
                alt = .{ .typ = .string };
            } else if (common.streq(tname, "array")) {
                alt = .{ .typ = .array };
            } else if (common.streq(tname, "map")) {
                alt = .{ .typ = .map };
            }

            var i: u8 = 0;
            while (i < count) : (i += 1) {
                if (tmp[i].typ == alt.typ and common.streq(tmp[i].struct_name, alt.struct_name)) break;
            }
            if (i == count) {
                if (count >= MaxTypeAlts) return error.TooManyTypeAlternatives;
                tmp[count] = alt;
                count += 1;
            }

            if (!self.match(.pipe)) break;
        }

        const alts = heap.bump(FieldTypeAlt, count) orelse return error.OutOfMemory;
        var ai: usize = 0;
        while (ai < count) : (ai += 1) {
            alts[ai] = tmp[ai];
        }
        return .{ .alts = alts[0..count] };
    }

    fn isNamedFuncDecl(self: *Compiler) bool {
        var lx = self.lex;
        const t1 = lx.next();
        if (t1.typ != .ident) return false;
        const t2 = lx.next();
        return t2.typ == .lparen;
    }

    fn namedFuncDecl(self: *Compiler) !void {
        const kw = self.cur;
        self.advance(); // consume 'func'
        if (self.cur.typ != .ident) return error.UnexpectedToken;
        const name = self.cur;
        self.advance(); // consume function name

        // current token is '('; funcLit emits the function value on stack
        try self.funcLit();

        if (self.inFunc()) {
            _ = try self.defineLocal(name.src);
        } else {
            const idx = try chunk.addConst(.{ .string = name.src });
            try chunk.emit2(@intFromEnum(Op.def_global), idx, kw.line);
        }
        self.matchOpt(.semicolon);
    }

    fn methodDecl(self: *Compiler) !void {
        const kw = self.cur;
        self.advance(); // func
        try self.consume(.lparen);
        if (self.cur.typ != .ident) return error.UnexpectedToken;
        const recv_name = self.cur.src;
        self.advance();
        if (self.cur.typ != .ident) return error.UnexpectedToken;
        const recv_type = self.cur.src;
        self.advance();
        try self.consume(.rparen);
        if (self.cur.typ != .ident) return error.UnexpectedToken;
        const method_name = self.cur.src;
        self.advance();

        var prefix: [1][]const u8 = .{recv_name};
        try self.compileFuncWithPrefix(prefix[0..]);

        const total = recv_type.len + 1 + method_name.len;
        const key_buf = heap.bump(u8, total) orelse return error.OutOfMemory;
        @memcpy(key_buf[0..recv_type.len], recv_type);
        key_buf[recv_type.len] = '.';
        @memcpy(key_buf[recv_type.len + 1 .. total], method_name);
        const key = key_buf[0..total];

        if (self.inFunc()) {
            _ = try self.defineLocal(key);
        } else {
            const idx = try chunk.addConst(.{ .string = key });
            try chunk.emit2(@intFromEnum(Op.def_global), idx, kw.line);
        }
        self.matchOpt(.semicolon);
    }

    fn varDecl(self: *Compiler) !void {
        const name = self.cur;
        self.advance();
        try self.consume(.colon_eq);
        try self.expr();
        if (self.inFunc()) {
            _ = try self.defineLocal(name.src);
        } else {
            const idx = try chunk.addConst(.{ .string = name.src });
            try chunk.emit2(@intFromEnum(Op.def_global), idx, name.line);
        }
        self.matchOpt(.semicolon);
    }

    fn isMultiBind(self: *Compiler, op: TT) bool {
        var lx = self.lex;
        const start_line = self.cur.line;
        var saw_comma = false;
        var expect_ident = false;
        var t = lx.next(); // token after first identifier
        while (t.typ != .eof) {
            if (t.line > start_line) return false;
            if (expect_ident) {
                if (t.typ != .ident) return false;
                expect_ident = false;
                t = lx.next();
                continue;
            }
            if (t.typ == .comma) {
                saw_comma = true;
                expect_ident = true;
                t = lx.next();
                continue;
            }
            return saw_comma and t.typ == op;
        }
        return false;
    }

    fn isMultiAssignEq(self: *Compiler) bool {
        var lx = self.lex;
        const start_line = self.cur.line;
        var depth: u32 = 0;
        var saw_comma = false;
        var t = lx.next(); // token after first identifier
        while (t.typ != .eof) {
            if (t.line > start_line) return false;
            switch (t.typ) {
                .lbracket, .lparen => depth += 1,
                .rbracket, .rparen => {
                    if (depth == 0) return false;
                    depth -= 1;
                },
                .comma => {
                    if (depth == 0) saw_comma = true;
                },
                .eq => return saw_comma and depth == 0,
                .colon_eq, .semicolon, .lbrace, .rbrace => return false,
                else => {},
            }
            t = lx.next();
        }
        return false;
    }

    fn parseNameList(self: *Compiler, out: *[MaxLocals]Token) !u8 {
        var count: u8 = 0;
        while (true) {
            if (self.cur.typ != .ident) return error.UnexpectedToken;
            if (count >= MaxLocals) return error.TooManyLocals;
            out[count] = self.cur;
            count += 1;
            self.advance();
            if (!self.match(.comma)) break;
        }
        return count;
    }

    fn emitExprListTuple(self: *Compiler) !u8 {
        var count: u8 = 0;
        try self.expr();
        count += 1;
        while (self.match(.comma)) {
            if (count == 255) return error.TooManyElements;
            try self.expr();
            count += 1;
        }
        if (count > 1) try chunk.emit2(@intFromEnum(Op.build_tuple), count, self.prev.line);
        return count;
    }

    fn parseAssignTargetList(self: *Compiler, targets: *[MaxLocals]AssignTarget, steps: *[MaxLocals * 8]AssignTargetStep) !struct { target_count: u8, step_count: u16 } {
        var tcount: u8 = 0;
        var scount: u16 = 0;
        while (true) {
            if (self.cur.typ != .ident) return error.UnexpectedToken;
            if (tcount >= MaxLocals) return error.TooManyLocals;
            const root = self.cur;
            self.advance();
            const start = scount;

            while (true) {
                if (self.match(.dot)) {
                    if (self.cur.typ != .ident) return error.ExpectedPropertyName;
                    if (scount >= steps.len) return error.TooManyElements;
                    steps[scount] = .{ .dot_name = self.cur.src };
                    scount += 1;
                    self.advance();
                    continue;
                }
                if (self.match(.lbracket)) {
                    if (scount >= steps.len) return error.TooManyElements;
                    if (self.cur.typ == .number) {
                        const n = common.parseFloat(self.cur.src) orelse return error.BadNumber;
                        steps[scount] = .{ .index_number = n };
                        scount += 1;
                        self.advance();
                    } else if (self.cur.typ == .string) {
                        steps[scount] = .{ .index_string = self.cur.src };
                        scount += 1;
                        self.advance();
                    } else {
                        return error.UnexpectedToken;
                    }
                    try self.consume(.rbracket);
                    continue;
                }
                break;
            }

            targets[tcount] = .{
                .root = root,
                .step_start = start,
                .step_count = @intCast(scount - start),
            };
            tcount += 1;
            if (!self.match(.comma)) break;
        }
        return .{ .target_count = tcount, .step_count = scount };
    }

    fn emitAssignTargetPath(self: *Compiler, target: AssignTarget, all_steps: []const AssignTargetStep) !void {
        const vidx = try chunk.addConst(.{ .string = MultiAssignValueScratch });
        if (target.step_count == 0) {
            try chunk.emit2(@intFromEnum(Op.get_global), vidx, target.root.line);
            try self.emitSetVar(target.root);
            return;
        }

        try self.emitGetVar(target.root);
        var i: u8 = 0;
        while (i + 1 < target.step_count) : (i += 1) {
            const st = all_steps[target.step_start + i];
            switch (st) {
                .dot_name => |name| try chunk.emitConst(.{ .string = name }, target.root.line),
                .index_number => |n| try chunk.emitConst(.{ .number = n }, target.root.line),
                .index_string => |s| try chunk.emitConst(.{ .string = s }, target.root.line),
            }
            try chunk.emitOp(.get_index, target.root.line);
        }

        const last = all_steps[target.step_start + target.step_count - 1];
        switch (last) {
            .dot_name => |name| try chunk.emitConst(.{ .string = name }, target.root.line),
            .index_number => |n| try chunk.emitConst(.{ .number = n }, target.root.line),
            .index_string => |s| try chunk.emitConst(.{ .string = s }, target.root.line),
        }
        try chunk.emit2(@intFromEnum(Op.get_global), vidx, target.root.line);
        try chunk.emitOp(.set_index, target.root.line);
    }

    fn multiBindStmt(self: *Compiler, is_decl: bool) !void {
        var names: [MaxLocals]Token = undefined;
        var targets: [MaxLocals]AssignTarget = undefined;
        var steps: [MaxLocals * 8]AssignTargetStep = undefined;
        var count: u8 = 0;
        var step_count: u16 = 0;

        if (is_decl) {
            count = try self.parseNameList(&names);
            if (count < 2) return error.UnexpectedToken;
            if (self.inFunc()) {
                var pre_i: u8 = 0;
                while (pre_i < count) : (pre_i += 1) {
                    try chunk.emitOp(.null_val, names[pre_i].line);
                    _ = try self.defineLocal(names[pre_i].src);
                }
            }
        } else {
            const parsed = try self.parseAssignTargetList(&targets, &steps);
            count = parsed.target_count;
            step_count = parsed.step_count;
            if (count < 2) return error.UnexpectedToken;
        }

        try self.consume(if (is_decl) .colon_eq else .eq);
        _ = try self.emitExprListTuple();
        try chunk.emit2(@intFromEnum(Op.tuple_check_arity), count, self.prev.line);

        var i: u8 = 0;
        while (i < count) : (i += 1) {
            if (is_decl) {
                try chunk.emitOp(.dup, names[i].line);
                try chunk.emit2(@intFromEnum(Op.tuple_get), i, names[i].line);
                if (self.inFunc()) {
                    try self.emitSetVar(names[i]);
                } else {
                    const idx = try chunk.addConst(.{ .string = names[i].src });
                    try chunk.emit2(@intFromEnum(Op.def_global), idx, names[i].line);
                }
            } else {
                const vidx = try chunk.addConst(.{ .string = MultiAssignValueScratch });
                try chunk.emitOp(.dup, targets[i].root.line);
                try chunk.emit2(@intFromEnum(Op.tuple_get), i, targets[i].root.line);
                try chunk.emit2(@intFromEnum(Op.def_global), vidx, targets[i].root.line);
                try self.emitAssignTargetPath(targets[i], steps[0..step_count]);
            }
        }
        try chunk.emitOp(.pop, self.prev.line);
        self.matchOpt(.semicolon);
    }

    fn stmt(self: *Compiler) anyerror!void {
        if (self.match(.kw_break)) {
            try self.emitBreak(self.prev.line);
            self.matchOpt(.semicolon);
            return;
        }
        if (self.match(.kw_continue)) {
            try self.emitContinue(self.prev.line);
            self.matchOpt(.semicolon);
            return;
        }
        if (self.match(.kw_return)) {
            try self.returnStmt();
            return;
        }
        if (self.match(.kw_if)) {
            try self.ifStmt();
            return;
        }
        if (self.match(.kw_for)) {
            try self.forStmt();
            return;
        }
        if (self.match(.kw_switch)) {
            try self.switchStmt();
            return;
        }

        if (self.check(.ident)) {
            const ptt = self.peekTT();
            if (ptt == .comma and self.isMultiBind(.colon_eq)) {
                try self.multiBindStmt(true);
                return;
            }
            if ((ptt == .comma or ptt == .dot or ptt == .lbracket) and self.isMultiAssignEq()) {
                try self.multiBindStmt(false);
                return;
            }
            if (ptt == .plus_plus or ptt == .minus_minus) {
                try self.incrStmt();
                return;
            }
            if (ptt == .plus_eq or ptt == .minus_eq or ptt == .star_eq or ptt == .slash_eq or ptt == .percent_eq or ptt == .amp_eq or ptt == .pipe_eq or ptt == .caret_eq or ptt == .lt_lt_eq or ptt == .gt_gt_eq) {
                try self.compoundStmt();
                return;
            }
            if (ptt == .eq) {
                try self.assignStmt();
                return;
            }
            if ((ptt == .dot or ptt == .lbracket) and self.isPropertyAssign()) {
                try self.propertyAssignStmt();
                return;
            }
            if (ptt == .lbracket and self.isIndexAssign()) {
                try self.indexAssignStmt();
                return;
            }
        }

        try self.expr();
        try chunk.emitOp(.pop, self.prev.line);
        self.matchOpt(.semicolon);
    }

    fn returnStmt(self: *Compiler) !void {
        if (!self.inFunc()) return error.ReturnOutsideFunction;
        if (self.check(.rbrace) or self.check(.eof) or self.check(.semicolon)) {
            try chunk.emitOp(.null_val, self.prev.line);
        } else {
            _ = try self.emitExprListTuple();
        }
        try chunk.emitOp(.ret, self.prev.line);
        self.matchOpt(.semicolon);
    }

    fn incrStmt(self: *Compiler) !void {
        const name = self.cur;
        self.advance();
        const is_inc = self.cur.typ == .plus_plus;
        self.advance();
        try self.emitGetVar(name);
        try chunk.emitConst(.{ .number = 1.0 }, name.line);
        try chunk.emitOp(if (is_inc) .add else .sub, name.line);
        try self.emitSetVar(name);
        self.matchOpt(.semicolon);
    }

    fn compoundStmt(self: *Compiler) !void {
        const name = self.cur;
        self.advance();
        const op_tok = self.cur;
        self.advance();
        try self.emitGetVar(name);
        try self.expr();
        const op: Op = switch (op_tok.typ) {
            .plus_eq => .add,
            .minus_eq => .sub,
            .star_eq => .mul,
            .slash_eq => .div,
            .percent_eq => .mod,
            .amp_eq => .bit_and,
            .pipe_eq => .bit_or,
            .caret_eq => .bit_xor,
            .lt_lt_eq => .shl,
            .gt_gt_eq => .shr,
            else => return error.UnexpectedToken,
        };
        try chunk.emitOp(op, op_tok.line);
        try self.emitSetVar(name);
        self.matchOpt(.semicolon);
    }

    fn assignStmt(self: *Compiler) !void {
        const name = self.cur;
        self.advance();
        try self.consume(.eq);
        try self.expr();
        try self.emitSetVar(name);
        self.matchOpt(.semicolon);
    }

    fn isIndexAssign(self: *Compiler) bool {
        var lx = self.lex;
        const start_line = self.cur.line;
        var depth: u32 = 0;
        var t = lx.next();
        while (t.typ != .eof) {
            if (t.line > start_line and depth == 0) return false;
            if (t.typ == .lbracket) {
                depth += 1;
            } else if (t.typ == .rbracket) {
                depth -= 1;
                if (depth == 0) return lx.next().typ == .eq;
            }
            t = lx.next();
        }
        return false;
    }

    fn isPropertyAssign(self: *Compiler) bool {
        var lx = self.lex;
        const start_line = self.cur.line;
        var depth: u32 = 0;
        var saw_path = false;
        var t = lx.next(); // token after first identifier
        while (t.typ != .eof) {
            if (t.line > start_line and depth == 0) return false;
            switch (t.typ) {
                .dot => saw_path = true,
                .lbracket => {
                    saw_path = true;
                    depth += 1;
                },
                .rbracket => {
                    if (depth == 0) return false;
                    depth -= 1;
                },
                .eq, .plus_eq, .minus_eq, .star_eq, .slash_eq, .percent_eq, .amp_eq, .pipe_eq, .caret_eq, .lt_lt_eq, .gt_gt_eq => return saw_path and depth == 0,
                .semicolon, .lbrace, .rbrace => return false,
                else => {},
            }
            t = lx.next();
        }
        return false;
    }

    fn indexAssignStmt(self: *Compiler) !void {
        const name = self.cur;
        self.advance();
        try self.emitGetVar(name);
        try self.consume(.lbracket);
        try self.expr();
        try self.consume(.rbracket);
        try self.consume(.eq);
        try self.expr();
        try chunk.emitOp(.set_index, name.line);
        self.matchOpt(.semicolon);
    }

    fn propertyAssignStmt(self: *Compiler) !void {
        const root = self.cur;
        self.advance();
        try self.emitGetVar(root);

        while (true) {
            if (self.match(.dot)) {
                if (self.cur.typ != .ident) return error.ExpectedPropertyName;
                const prop = self.cur;
                self.advance();
                try chunk.emitConst(.{ .string = prop.src }, prop.line);
                if (self.check(.eq) or self.check(.plus_eq) or self.check(.minus_eq) or self.check(.star_eq) or self.check(.slash_eq) or self.check(.percent_eq) or self.check(.amp_eq) or self.check(.pipe_eq) or self.check(.caret_eq) or self.check(.lt_lt_eq) or self.check(.gt_gt_eq)) break;
                try chunk.emitOp(.get_index, prop.line);
                continue;
            }

            if (self.match(.lbracket)) {
                try self.expr();
                try self.consume(.rbracket);
                if (self.check(.eq) or self.check(.plus_eq) or self.check(.minus_eq) or self.check(.star_eq) or self.check(.slash_eq) or self.check(.percent_eq) or self.check(.amp_eq) or self.check(.pipe_eq) or self.check(.caret_eq) or self.check(.lt_lt_eq) or self.check(.gt_gt_eq)) break;
                try chunk.emitOp(.get_index, self.prev.line);
                continue;
            }

            return error.UnexpectedToken;
        }

        const op_tok = self.cur;
        if (self.match(.eq)) {
            try self.expr();
            try chunk.emitOp(.set_index, self.prev.line);
            self.matchOpt(.semicolon);
            return;
        }

        if (self.match(.plus_eq) or self.match(.minus_eq) or self.match(.star_eq) or self.match(.slash_eq) or self.match(.percent_eq) or self.match(.amp_eq) or self.match(.pipe_eq) or self.match(.caret_eq) or self.match(.lt_lt_eq) or self.match(.gt_gt_eq)) {
            // duplicate container+key pair to read old value, then compute and write back
            try chunk.emitOp(.dup2, op_tok.line);
            try chunk.emitOp(.get_index, op_tok.line); // old value
            try self.expr();
            const op: Op = switch (op_tok.typ) {
                .plus_eq => .add,
                .minus_eq => .sub,
                .star_eq => .mul,
                .slash_eq => .div,
                .percent_eq => .mod,
                .amp_eq => .bit_and,
                .pipe_eq => .bit_or,
                .caret_eq => .bit_xor,
                .lt_lt_eq => .shl,
                .gt_gt_eq => .shr,
                else => return error.UnexpectedToken,
            };
            try chunk.emitOp(op, op_tok.line);
            try chunk.emitOp(.set_index, op_tok.line);
            self.matchOpt(.semicolon);
            return;
        }

        return error.UnexpectedToken;
    }

    fn ifStmt(self: *Compiler) anyerror!void {
        const local_base: u8 = if (self.inFunc()) self.currentScope().local_count else 0;

        if (self.hasInitSemicolon()) {
            if (self.check(.ident) and self.peekTT() == .colon_eq) {
                try self.varDecl();
            } else if (self.check(.ident) and self.peekTT() == .eq) {
                try self.assignStmt();
            } else {
                try self.expr();
                try chunk.emitOp(.pop, self.prev.line);
                self.matchOpt(.semicolon);
            }
        }

        try self.expr();
        try self.consume(.lbrace);

        const then_j = try chunk.emitJump(.jump_if_false, self.prev.line);
        try chunk.emitOp(.pop, self.prev.line);
        try self.block();

        const else_j = try chunk.emitJump(.jump, self.prev.line);
        try chunk.patchJump(then_j);
        try chunk.emitOp(.pop, self.prev.line);

        if (self.match(.kw_else)) {
            if (self.match(.kw_if)) {
                try self.ifStmt();
            } else {
                try self.consume(.lbrace);
                try self.block();
            }
        }
        try chunk.patchJump(else_j);
        try self.cleanupLocals(local_base, self.prev.line);
    }

    fn hasInitSemicolon(self: *Compiler) bool {
        var lx = self.lex;
        var t = self.cur;
        while (t.typ != .eof and t.typ != .lbrace and t.typ != .rbrace) {
            if (t.typ == .semicolon) return true;
            t = lx.next();
        }
        return false;
    }

    fn forStmt(self: *Compiler) anyerror!void {
        if (self.isForIn()) {
            try self.forInStmt();
        } else if (self.isCStyleFor()) {
            try self.cForStmt();
        } else {
            try self.whileForStmt();
        }
    }

    fn isForIn(self: *Compiler) bool {
        var lx = self.lex;
        var t = self.cur;
        while (t.typ != .eof and t.typ != .lbrace and t.typ != .rbrace) {
            if (t.typ == .kw_in) return true;
            if (t.typ == .semicolon) return false;
            t = lx.next();
        }
        return false;
    }

    fn declareLoopVar(self: *Compiler, name: Token) !void {
        if (self.inFunc()) {
            try chunk.emitOp(.null_val, name.line);
            _ = try self.defineLocal(name.src);
        } else {
            try chunk.emitOp(.null_val, name.line);
            const idx = try chunk.addConst(.{ .string = name.src });
            try chunk.emit2(@intFromEnum(Op.def_global), idx, name.line);
        }
    }

    fn assignLoopVar(self: *Compiler, name: Token) !void {
        try self.emitSetVar(name);
    }

    fn forInStmt(self: *Compiler) anyerror!void {
        const local_base: u8 = if (self.inFunc()) self.currentScope().local_count else 0;
        if (self.cur.typ != .ident) return error.UnexpectedToken;
        const kname = self.cur;
        self.advance();
        var vname: ?Token = null;
        if (self.match(.comma)) {
            if (self.cur.typ != .ident) return error.UnexpectedToken;
            vname = self.cur;
            self.advance();
        }
        try self.consume(.kw_in);

        try self.declareLoopVar(kname);
        if (vname) |vn| try self.declareLoopVar(vn);

        try self.expr(); // iterable
        try chunk.emitOp(.iter_init, self.prev.line);

        const loop_start = chunk.g_code_len;
        try self.pushLoop(loop_start, local_base);
        try chunk.emitOp(if (vname == null) .iter_next1 else .iter_next2, self.prev.line);
        const exit_j = try chunk.emitJump(.jump_if_false, self.prev.line);
        try chunk.emitOp(.pop, self.prev.line); // pop condition true

        if (vname) |vn| {
            // stack: iter, key, value
            try self.assignLoopVar(vn);
            try self.assignLoopVar(kname);
        } else {
            // stack: iter, value
            try self.assignLoopVar(kname);
        }

        try self.consume(.lbrace);
        try self.block();
        try chunk.emitLoop(loop_start, self.prev.line);

        try chunk.patchJump(exit_j);
        try chunk.emitOp(.pop, self.prev.line); // pop false condition
        try chunk.emitOp(.pop, self.prev.line); // pop iterator

        const loop = self.popLoop();
        var i: usize = 0;
        while (i < loop.break_count) : (i += 1) {
            try chunk.patchJump(loop.break_offsets[i]);
        }

        try self.cleanupLocals(local_base, self.prev.line);
    }

    fn switchStmt(self: *Compiler) anyerror!void {
        try self.expr();
        try self.consume(.lbrace);

        var end_jumps: [MaxSwitchJumps]usize = undefined;
        var end_count: usize = 0;
        var saw_default = false;

        while (!self.check(.rbrace) and !self.check(.eof)) {
            if (self.match(.kw_case)) {
                try chunk.emitOp(.dup, self.prev.line);
                try self.expr();
                try chunk.emitOp(.eq, self.prev.line);
                const next_case = try chunk.emitJump(.jump_if_false, self.prev.line);
                try chunk.emitOp(.pop, self.prev.line);
                try self.consume(.lbrace);
                try self.block();
                if (end_count >= MaxSwitchJumps) return error.TooManySwitchCases;
                end_jumps[end_count] = try chunk.emitJump(.jump, self.prev.line);
                end_count += 1;
                try chunk.patchJump(next_case);
                try chunk.emitOp(.pop, self.prev.line);
                continue;
            }

            if (self.match(.kw_default)) {
                if (saw_default) return error.DuplicateDefaultCase;
                saw_default = true;
                try self.consume(.lbrace);
                try self.block();
                if (end_count >= MaxSwitchJumps) return error.TooManySwitchCases;
                end_jumps[end_count] = try chunk.emitJump(.jump, self.prev.line);
                end_count += 1;
                continue;
            }

            return error.UnexpectedToken;
        }

        try self.consume(.rbrace);
        try chunk.emitOp(.pop, self.prev.line);

        var i: usize = 0;
        while (i < end_count) : (i += 1) {
            try chunk.patchJump(end_jumps[i]);
        }
    }

    fn isCStyleFor(self: *Compiler) bool {
        var lx = self.lex;
        var t = self.cur;
        while (t.typ != .eof and t.typ != .lbrace and t.typ != .rbrace) {
            if (t.typ == .semicolon) return true;
            t = lx.next();
        }
        return false;
    }

    fn whileForStmt(self: *Compiler) anyerror!void {
        const loop_start = chunk.g_code_len;
        try self.pushLoop(loop_start, self.loopKeepBase());
        try self.expr();
        try self.consume(.lbrace);
        const exit_j = try chunk.emitJump(.jump_if_false, self.prev.line);
        try chunk.emitOp(.pop, self.prev.line);
        try self.block();
        try chunk.emitLoop(loop_start, self.prev.line);
        try chunk.patchJump(exit_j);
        try chunk.emitOp(.pop, self.prev.line);
        const loop = self.popLoop();
        var i: usize = 0;
        while (i < loop.break_count) : (i += 1) {
            try chunk.patchJump(loop.break_offsets[i]);
        }
    }

    fn cForStmt(self: *Compiler) anyerror!void {
        const local_base: u8 = if (self.inFunc()) self.currentScope().local_count else 0;

        if (self.match(.semicolon)) {} else if (self.check(.ident) and self.peekTT() == .colon_eq) {
            try self.varDecl();
        } else if (self.check(.ident) and self.peekTT() == .eq) {
            try self.assignStmt();
        } else {
            try self.expr();
            try chunk.emitOp(.pop, self.prev.line);
            try self.consume(.semicolon);
        }

        var loop_start = chunk.g_code_len;
        var exit_j: ?usize = null;

        if (!self.match(.semicolon)) {
            try self.expr();
            try self.consume(.semicolon);
            exit_j = try chunk.emitJump(.jump_if_false, self.prev.line);
            try chunk.emitOp(.pop, self.prev.line);
        }

        if (!self.check(.lbrace)) {
            const body_j = try chunk.emitJump(.jump, self.prev.line);
            const post_start = chunk.g_code_len;
            if (self.check(.ident) and (self.peekTT() == .plus_plus or self.peekTT() == .minus_minus)) {
                try self.incrStmt();
            } else if (self.check(.ident) and self.peekTT() == .eq) {
                try self.assignStmt();
            } else if (self.check(.ident)) {
                const ptt = self.peekTT();
                if (ptt == .plus_eq or ptt == .minus_eq or ptt == .star_eq or ptt == .slash_eq or ptt == .percent_eq or ptt == .amp_eq or ptt == .pipe_eq or ptt == .caret_eq or ptt == .lt_lt_eq or ptt == .gt_gt_eq) {
                    try self.compoundStmt();
                } else {
                    try self.expr();
                    try chunk.emitOp(.pop, self.prev.line);
                }
            } else {
                try self.expr();
                try chunk.emitOp(.pop, self.prev.line);
            }
            try chunk.emitLoop(loop_start, self.prev.line);
            loop_start = post_start;
            try chunk.patchJump(body_j);
        }

        try self.pushLoop(loop_start, self.loopKeepBase());
        try self.consume(.lbrace);
        try self.block();
        try chunk.emitLoop(loop_start, self.prev.line);

        if (exit_j) |j| {
            try chunk.patchJump(j);
            try chunk.emitOp(.pop, self.prev.line);
        }

        const loop = self.popLoop();
        var i: usize = 0;
        while (i < loop.break_count) : (i += 1) {
            try chunk.patchJump(loop.break_offsets[i]);
        }

        try self.cleanupLocals(local_base, self.prev.line);
    }

    fn block(self: *Compiler) anyerror!void {
        const local_base: u8 = if (self.inFunc()) self.currentScope().local_count else 0;
        while (!self.check(.rbrace) and !self.check(.eof)) try self.decl();
        try self.consume(.rbrace);
        try self.cleanupLocals(local_base, self.prev.line);
    }

    fn funcLit(self: *Compiler) anyerror!void {
        try self.compileFuncWithPrefix(&[_][]const u8{});
    }

    fn compileFuncWithPrefix(self: *Compiler, prefix: []const []const u8) anyerror!void {
        try self.consume(.lparen);
        var param_names: [MaxLocals][]const u8 = undefined;
        var param_types: [MaxLocals]FieldTypeSpec = undefined;
        var arity: u8 = 0;

        const any_alts = heap.bump(FieldTypeAlt, 1) orelse return error.OutOfMemory;
        any_alts[0] = .{ .typ = .any };
        const any_spec: FieldTypeSpec = .{ .alts = any_alts[0..1] };

        if (prefix.len > MaxLocals) return error.TooManyParams;
        var pi0: usize = 0;
        while (pi0 < prefix.len) : (pi0 += 1) {
            param_names[arity] = prefix[pi0];
            param_types[arity] = any_spec;
            arity += 1;
        }

        if (!self.check(.rparen)) {
            while (true) {
                if (arity >= MaxLocals) return error.TooManyParams;
                if (self.cur.typ != .ident) return error.UnexpectedToken;
                param_names[arity] = self.cur.src;
                var ptype: FieldTypeSpec = any_spec;
                arity += 1;
                self.advance();
                if (self.match(.colon)) {
                    ptype = try self.parseFieldTypeSpec();
                } else if (self.cur.typ == .question or self.cur.typ == .ident) {
                    // Also support `name Type` (and `name ?Type`) parameter annotations.
                    ptype = try self.parseFieldTypeSpec();
                }
                param_types[arity - 1] = ptype;
                if (!self.match(.comma)) break;
            }
        }
        try self.consume(.rparen);

        const jump_over = try chunk.emitJump(.jump, self.prev.line);
        const func_ip = chunk.g_code_len;

        if (self.scope_depth >= MaxScopes) return error.TooManyNestedFunctions;
        self.scopes[self.scope_depth] = .{};
        self.scope_depth += 1;
        const scope = self.currentScope();

        var pi: u8 = 0;
        while (pi < arity) : (pi += 1) {
            scope.locals[pi] = .{ .name = param_names[pi] };
        }
        scope.local_count = arity;

        try self.consume(.lbrace);
        const body_local_base = arity;
        while (!self.check(.rbrace) and !self.check(.eof)) try self.decl();
        try self.consume(.rbrace);
        try self.cleanupLocals(body_local_base, self.prev.line);

        try chunk.emitOp(.null_val, self.prev.line);
        try chunk.emitOp(.ret, self.prev.line);

        self.scope_depth -= 1;
        try chunk.patchJump(jump_over);

        const uv_count = scope.upvalue_count;
        const slots = heap.bump(u8, uv_count) orelse return error.OutOfMemory;
        var ui: u8 = 0;
        while (ui < uv_count) : (ui += 1) {
            const uv = scope.upvalues[ui];
            const flag: u8 = if (uv.from_upvalue) @as(u8, 0x80) else @as(u8, 0x00);
            slots[ui] = flag | uv.index;
        }

        const ptypes = heap.bump(FieldTypeSpec, arity) orelse return error.OutOfMemory;
        var has_typed_params = false;
        var pti: u8 = 0;
        while (pti < arity) : (pti += 1) {
            ptypes[pti] = param_types[pti];
            if (!(param_types[pti].alts.len == 1 and param_types[pti].alts[0].typ == .any)) {
                has_typed_params = true;
            }
        }

        const func_obj = heap.allocObject() orelse return error.OutOfMemory;
        func_obj.* = .{ .function = .{
            .ip = func_ip,
            .arity = arity,
            .capture_slots = slots[0..uv_count],
            .param_types = ptypes[0..arity],
            .has_typed_params = has_typed_params,
        } };
        const cidx = try chunk.addConst(.{ .object = func_obj });
        try chunk.emit2(@intFromEnum(Op.make_closure), cidx, self.prev.line);
    }

    fn skipTypeSpec(self: *Compiler) !void {
        _ = self.match(.question);
        if (self.cur.typ != .ident) return error.UnexpectedToken;
        self.advance();
        while (self.match(.pipe)) {
            if (self.cur.typ != .ident) return error.UnexpectedToken;
            self.advance();
        }
    }

    fn expr(self: *Compiler) !void {
        try self.parsePrecedence(.assign);
    }

    fn parsePrecedence(self: *Compiler, p: Prec) anyerror!void {
        self.advance();
        const pfx = self.prev.typ;
        switch (pfx) {
            .number => try self.numLit(),
            .string => try self.strLitExpr(),
            .rune => try self.runeLitExpr(),
            .kw_true => try chunk.emitOp(.true_val, self.prev.line),
            .kw_false => try chunk.emitOp(.false_val, self.prev.line),
            .kw_null => try chunk.emitOp(.null_val, self.prev.line),
            .ident => try self.varExpr(self.prev),
            .minus, .bang, .tilde => try self.unaryExpr(pfx),
            .lparen => {
                try self.expr();
                try self.consume(.rparen);
            },
            .lbracket => try self.arrayLit(),
            .lbrace => try self.mapLit(),
            .kw_func => try self.funcLit(),
            .kw_import => try self.importExpr(),
            else => return error.ExpectedExpression,
        }
        while (@intFromEnum(p) <= @intFromEnum(tokPrec(self.cur.typ))) {
            self.advance();
            try self.infixExpr(self.prev.typ);
        }
    }

    fn numLit(self: *Compiler) !void {
        const n = common.parseFloat(self.prev.src) orelse return error.BadNumber;
        try chunk.emitConst(.{ .number = n }, self.prev.line);
    }

    fn strLitExpr(self: *Compiler) !void {
        try chunk.emitConst(.{ .string = self.prev.src }, self.prev.line);
    }

    fn runeLitExpr(self: *Compiler) !void {
        const raw = self.prev.src;
        if (raw.len < 3) return error.UnexpectedToken; // `x`
        const body = raw[1 .. raw.len - 1];
        var it = std.unicode.Utf8View.init(body) catch return error.TypeError;
        var iter = it.iterator();
        const cp = iter.nextCodepoint() orelse return error.UnexpectedToken;
        if (iter.nextCodepoint() != null) return error.UnexpectedToken;
        try chunk.emitConst(.{ .rune = @intCast(cp) }, self.prev.line);
    }

    fn varExpr(self: *Compiler, name: Token) !void {
        if ((common.streq(name.src, "int") or common.streq(name.src, "float") or common.streq(name.src, "bool")) and self.match(.lparen)) {
            try self.expr();
            try self.consume(.rparen);
            if (common.streq(name.src, "int")) {
                try chunk.emitOp(.cast_int, name.line);
            } else if (common.streq(name.src, "float")) {
                try chunk.emitOp(.cast_float, name.line);
            } else {
                try chunk.emitOp(.cast_bool, name.line);
            }
            return;
        }
        if (self.check(.lbrace) and self.looksLikeStructLiteral()) {
            try self.structInstanceLit(name);
            return;
        }
        try self.emitGetVar(name);
    }

    fn looksLikeStructLiteral(self: *Compiler) bool {
        var lx = self.lex;
        var t = lx.next(); // first token inside '{'
        if (t.typ == .rbrace) return true; // empty literal form (if ever allowed)
        if (!(t.typ == .ident or t.typ == .string)) return false;
        t = lx.next();
        return t.typ == .colon;
    }

    fn structInstanceLit(self: *Compiler, type_name: Token) !void {
        try self.emitGetVar(type_name);
        try self.consume(.lbrace);
        var count: u8 = 0;
        if (!self.check(.rbrace)) {
            while (true) {
                if (count == 255) return error.TooManyElements;
                if (self.check(.ident)) {
                    const key_tok = self.cur;
                    self.advance();
                    try chunk.emitConst(.{ .string = key_tok.src }, key_tok.line);
                } else if (self.check(.string)) {
                    try chunk.emitConst(.{ .string = self.cur.src }, self.cur.line);
                    self.advance();
                } else return error.UnexpectedToken;
                try self.consume(.colon);
                try self.expr();
                count += 1;
                if (!self.match(.comma)) break;
            }
        }
        try self.consume(.rbrace);
        try chunk.emit2(@intFromEnum(Op.build_struct_instance), count, type_name.line);
    }

    fn arrayLit(self: *Compiler) !void {
        var count: u8 = 0;
        if (!self.check(.rbracket)) {
            while (true) {
                try self.expr();
                if (count == 255) return error.TooManyElements;
                count += 1;
                if (!self.match(.comma)) break;
            }
        }
        try self.consume(.rbracket);
        try chunk.emit2(@intFromEnum(Op.build_array), count, self.prev.line);
    }

    fn mapLit(self: *Compiler) !void {
        var count: u8 = 0;
        if (!self.check(.rbrace)) {
            while (true) {
                if (count == 255) return error.TooManyElements;

                if (self.check(.ident)) {
                    const key_tok = self.cur;
                    self.advance();
                    try chunk.emitConst(.{ .string = key_tok.src }, key_tok.line);
                } else {
                    try self.expr();
                }

                try self.consume(.colon);
                try self.expr();
                count += 1;
                if (!self.match(.comma)) break;
            }
        }
        try self.consume(.rbrace);
        try chunk.emit2(@intFromEnum(Op.build_map), count, self.prev.line);
    }

    fn unaryExpr(self: *Compiler, tt: TT) !void {
        try self.parsePrecedence(.unary);
        switch (tt) {
            .minus => try chunk.emitOp(.neg, self.prev.line),
            .bang => try chunk.emitOp(.not, self.prev.line),
            .tilde => try chunk.emitOp(.bit_not, self.prev.line),
            else => unreachable,
        }
    }

    fn infixExpr(self: *Compiler, tt: TT) anyerror!void {
        const line = self.prev.line;

        if (tt == .dot) {
            if (self.cur.typ != .ident) return error.ExpectedPropertyName;
            const prop = self.cur;
            self.advance();
            if (self.match(.lparen)) {
                var argc: u8 = 0;
                if (!self.check(.rparen)) {
                    while (true) {
                        try self.expr();
                        argc += 1;
                        if (!self.match(.comma)) break;
                    }
                }
                try self.consume(.rparen);
                const midx = try chunk.addConst(.{ .string = prop.src });
                try chunk.emitByte(@intFromEnum(Op.invoke_method), line);
                try chunk.emitByte(midx, line);
                try chunk.emitByte(argc, line);
                return;
            }
            try chunk.emitConst(.{ .string = prop.src }, line);
            try chunk.emitOp(.get_index, line);
            return;
        }

        if (tt == .lbracket) {
            if (self.match(.colon)) {
                var flags: u8 = 0;
                if (!self.check(.rbracket)) {
                    try self.expr();
                    flags |= 0b10;
                }
                try self.consume(.rbracket);
                try chunk.emit2(@intFromEnum(Op.get_slice), flags, line);
                return;
            }

            try self.expr();
            if (self.match(.colon)) {
                var flags: u8 = 0b01;
                if (!self.check(.rbracket)) {
                    try self.expr();
                    flags |= 0b10;
                }
                try self.consume(.rbracket);
                try chunk.emit2(@intFromEnum(Op.get_slice), flags, line);
                return;
            }

            try self.consume(.rbracket);
            try chunk.emitOp(.get_index, line);
            return;
        }
        if (tt == .lparen) {
            var argc: u8 = 0;
            if (!self.check(.rparen)) {
                while (true) {
                    try self.expr();
                    argc += 1;
                    if (!self.match(.comma)) break;
                }
            }
            try self.consume(.rparen);
            try chunk.emit2(@intFromEnum(Op.call), argc, line);
            return;
        }

        const p = tokPrec(tt);
        if (tt == .amp_amp) {
            const j = try chunk.emitJump(.jump_if_false, line);
            try chunk.emitOp(.pop, line);
            try self.parsePrecedence(p.next());
            try chunk.patchJump(j);
            return;
        }
        if (tt == .pipe_pipe) {
            const j_else = try chunk.emitJump(.jump_if_false, line);
            const j_end = try chunk.emitJump(.jump, line);
            try chunk.patchJump(j_else);
            try chunk.emitOp(.pop, line);
            try self.parsePrecedence(p.next());
            try chunk.patchJump(j_end);
            return;
        }

        try self.parsePrecedence(p.next());
        switch (tt) {
            .plus => try chunk.emitOp(.add, line),
            .minus => try chunk.emitOp(.sub, line),
            .star => try chunk.emitOp(.mul, line),
            .slash => try chunk.emitOp(.div, line),
            .percent => try chunk.emitOp(.mod, line),
            .amp => try chunk.emitOp(.bit_and, line),
            .pipe => try chunk.emitOp(.bit_or, line),
            .caret => try chunk.emitOp(.bit_xor, line),
            .lt_lt => try chunk.emitOp(.shl, line),
            .gt_gt => try chunk.emitOp(.shr, line),
            .eq_eq => try chunk.emitOp(.eq, line),
            .bang_eq => {
                try chunk.emitOp(.eq, line);
                try chunk.emitOp(.not, line);
            },
            .gt => try chunk.emitOp(.gt, line),
            .gt_eq => {
                try chunk.emitOp(.lt, line);
                try chunk.emitOp(.not, line);
            },
            .lt => try chunk.emitOp(.lt, line),
            .lt_eq => {
                try chunk.emitOp(.gt, line);
                try chunk.emitOp(.not, line);
            },
            else => unreachable,
        }
    }

    fn advance(self: *Compiler) void {
        self.prev = self.cur;
        self.cur = self.lex.next();
    }
    fn check(self: *Compiler, tt: TT) bool {
        return self.cur.typ == tt;
    }
    fn match(self: *Compiler, tt: TT) bool {
        if (!self.check(tt)) return false;
        self.advance();
        return true;
    }
    fn matchOpt(self: *Compiler, tt: TT) void {
        _ = self.match(tt);
    }
    fn consume(self: *Compiler, tt: TT) !void {
        if (self.cur.typ == tt) {
            self.advance();
            return;
        }
        return error.UnexpectedToken;
    }
    fn peekTT(self: *Compiler) TT {
        var lx = self.lex;
        return lx.next().typ;
    }

    fn importExpr(self: *Compiler) !void {
        try self.consume(.lparen);
        if (self.cur.typ != .string) return error.ExpectedStringLiteral;
        const name = self.cur.src;
        self.advance();
        try self.consume(.rparen);
        if (!common.streq(name, "std")) return error.UnsupportedImportModule;
        try chunk.emitOp(.import_std, self.prev.line);
    }
};

fn tokPrec(tt: TT) Prec {
    return switch (tt) {
        .pipe_pipe => .or_,
        .amp_amp => .and_,
        .eq_eq, .bang_eq => .eq_,
        .pipe => .bit_or,
        .caret => .bit_xor,
        .amp => .bit_and,
        .lt_lt, .gt_gt => .shift,
        .lt, .lt_eq, .gt, .gt_eq => .cmp,
        .plus, .minus => .term,
        .star, .slash, .percent => .factor,
        .lbracket, .lparen, .dot => .call,
        else => .none,
    };
}
