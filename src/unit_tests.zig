//! Copyright 2026 Andrea Vaccaro
//! Licensed under the Apache License, Version 2.0
//! http://www.apache.org/licenses/LICENSE-2.0
//!
//! This file is part of "Rapto".
//! It contains the implementation of unit tests and semantic analysis.

comptime {
    _ = @import("Aof.zig");
    _ = @import("code.zig");
    _ = @import("frames.zig");
    _ = @import("main.zig");
    _ = @import("Memory.zig");
    _ = @import("Memory/object.zig");
    _ = @import("Memory/Key.zig");
    _ = @import("Memory/value.zig");
    _ = @import("Memory/value/collection.zig");
    _ = @import("Memory/value/collection/List.zig");
    _ = @import("Memory/value/collection/Map.zig");
    _ = @import("Memory/value/scalar.zig");
    _ = @import("Memory/value/scalar/Decimal.zig");
    _ = @import("Memory/value/scalar/Flag.zig");
    _ = @import("Memory/value/scalar/Integer.zig");
    _ = @import("Memory/value/scalar/Point.zig");
    _ = @import("Memory/value/scalar/String.zig");
    _ = @import("Memory/value/scalar/Void.zig");
    _ = @import("state_machine.zig");
    _ = @import("tagged_pointer.zig");
    _ = @import("Query.zig");
    _ = @import("Query/Flags.zig");
    _ = @import("zprof.zig");
}
