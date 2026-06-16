//! Copyright 2026 Andrea Vaccaro
//! Licensed under the Apache License, Version 2.0
//! http://www.apache.org/licenses/LICENSE-2.0
//!
//! This file is part of "Rapto".
//! It contains the implementation of unit tests and semantic analysis.

comptime {
    _ = @import("Aof.zig");
    _ = @import("cli.zig");
    _ = @import("cli/Server.zig");
    _ = @import("code.zig");
    _ = @import("frames.zig");
    _ = @import("main.zig");
    _ = @import("Memory.zig");
    _ = @import("Memory/object.zig");
    _ = @import("Memory/object/Key.zig");
    _ = @import("Memory/object/value.zig");
    _ = @import("Memory/object/tagged_pointer.zig");
    _ = @import("Memory/object/value/collection.zig");
    _ = @import("Memory/object/value/collection/List.zig");
    _ = @import("Memory/object/value/collection/Map.zig");
    _ = @import("Memory/object/value/scalar.zig");
    _ = @import("Memory/object/value/scalar/Decimal.zig");
    _ = @import("Memory/object/value/scalar/Flag.zig");
    _ = @import("Memory/object/value/scalar/Integer.zig");
    _ = @import("Memory/object/value/scalar/Point.zig");
    _ = @import("Memory/object/value/scalar/String.zig");
    _ = @import("Memory/object/value/scalar/Void.zig");
    _ = @import("state_machine.zig");
    _ = @import("Query.zig");
    _ = @import("Query/Flags.zig");
    _ = @import("zprof.zig");
}
