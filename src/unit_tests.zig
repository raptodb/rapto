//! Copyright 2026 Andrea Vaccaro
//! Licensed under the Apache License, Version 2.0
//! http://www.apache.org/licenses/LICENSE-2.0
//!
//! This file is part of "Rapto".
//! It contains the implementation of unit tests.

comptime {
    _ = @import("Memory.zig");
    _ = @import("Memory/object.zig");
    _ = @import("Memory/tagged_pointer.zig");
    _ = @import("field.zig");
    _ = @import("field/collection.zig");
    _ = @import("field/collection/list.zig");
    _ = @import("field/collection/map.zig");
    _ = @import("field/scalar.zig");
    _ = @import("field/scalar/decimal.zig");
    _ = @import("field/scalar/flag.zig");
    _ = @import("field/scalar/integer.zig");
    _ = @import("field/scalar/point.zig");
    _ = @import("field/scalar/string.zig");
    _ = @import("field/scalar/void.zig");
    _ = @import("field/types.zig");
    _ = @import("Task.zig");
    _ = @import("Task/Query.zig");
    _ = @import("Task/Query/Flags.zig");
    _ = @import("zprof.zig");
}
