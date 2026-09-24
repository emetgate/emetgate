pub const repeated_capture_query = "q:((statement_block (_)+ @violation) (#eq? @violation @violation))";

pub const many_captures_query = "q:((statement_block" ++ " (_) @violation ." ** 200 ++ " (_) @violation) (#eq? @violation @violation))";

pub const wide_body = "{\n" ++ "  a;\n" ** 20_000 ++ "}";
