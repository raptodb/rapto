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
    _ = @import("field/collection/List.zig");
    _ = @import("field/collection/Map.zig");
    _ = @import("field/scalar.zig");
    _ = @import("field/scalar/Decimal.zig");
    _ = @import("field/scalar/Flag.zig");
    _ = @import("field/scalar/Integer.zig");
    _ = @import("field/scalar/Point.zig");
    _ = @import("field/scalar/String.zig");
    _ = @import("field/scalar/Void.zig");
    _ = @import("Task.zig");
    _ = @import("Task/Query.zig");
    _ = @import("Task/Query/Flags.zig");
    _ = @import("zprof.zig");
}
