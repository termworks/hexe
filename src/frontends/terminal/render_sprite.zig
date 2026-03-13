const std = @import("std");
const pop = @import("pop");
const vaxis = @import("vaxis");

pub fn drawSpriteOverlay(
    renderer: anytype,
    pane_x: u16,
    pane_y: u16,
    pane_width: u16,
    pane_height: u16,
    sprite_content: []const u8,
    pokemon_config: pop.widgets.PokemonConfig,
) void {
    const widgets = pop.widgets;

    var lines = std.mem.splitScalar(u8, sprite_content, '\n');
    var max_visual_width: usize = 0;
    var line_count: usize = 0;

    var temp_lines: std.ArrayList([]const u8) = .empty;
    defer temp_lines.deinit(renderer.allocator);

    while (lines.next()) |line| {
        temp_lines.append(renderer.allocator, line) catch continue;
        const visual_width = widgets.pokemon.estimateVisualWidth(line);
        if (visual_width > max_visual_width) {
            max_visual_width = visual_width;
        }
        line_count += 1;
    }

    const sprite_width: u16 = @intCast(@min(max_visual_width, pane_width));
    const sprite_height: u16 = @intCast(line_count);

    const pos = widgets.pokemon.calculatePosition(
        pokemon_config,
        pane_x,
        pane_y,
        pane_width,
        pane_height,
        sprite_width,
        sprite_height,
    );
    const start_x = pos.x;
    const start_y = pos.y;

    for (temp_lines.items, 0..) |line, i| {
        const y = start_y + @as(u16, @intCast(i));
        if (y >= pane_y + pane_height) break;

        var x = start_x;
        var j: usize = 0;
        var in_escape = false;
        var escape_buf: [128]u8 = undefined;
        var escape_len: usize = 0;
        var current_style: vaxis.Style = .{};

        while (j < line.len and x < pane_x + pane_width) {
            if (line[j] == 0x1b) {
                in_escape = true;
                escape_len = 0;
                escape_buf[escape_len] = line[j];
                escape_len += 1;
                j += 1;
            } else if (in_escape) {
                if (escape_len < escape_buf.len) {
                    escape_buf[escape_len] = line[j];
                    escape_len += 1;
                }
                if (line[j] == 'm') {
                    parseSGR(escape_buf[0..escape_len], &current_style);
                    in_escape = false;
                }
                j += 1;
            } else {
                const char_len = std.unicode.utf8ByteSequenceLength(line[j]) catch 1;
                if (j + char_len <= line.len) {
                    const codepoint = std.unicode.utf8Decode(line[j..][0..char_len]) catch {
                        j += 1;
                        continue;
                    };
                    if (codepoint != ' ') {
                        renderer.setVaxisCell(x, y, .{
                            .char = .{ .grapheme = line[j .. j + char_len], .width = 1 },
                            .style = current_style,
                        });
                    }
                    x += 1;
                    j += char_len;
                } else {
                    j += 1;
                }
            }
        }
    }
}

fn parseSGR(seq: []const u8, style: *vaxis.Style) void {
    if (seq.len < 3) return;
    if (seq[0] != 0x1b or seq[1] != '[') return;

    const params_end = std.mem.indexOfScalar(u8, seq, 'm') orelse return;
    const params = seq[2..params_end];

    var params_iter = std.mem.splitScalar(u8, params, ';');
    var param_list: [8]u8 = undefined;
    var param_count: usize = 0;

    while (params_iter.next()) |param_str| {
        if (param_count >= param_list.len) break;
        param_list[param_count] = std.fmt.parseInt(u8, param_str, 10) catch continue;
        param_count += 1;
    }

    if (param_count >= 5 and param_list[0] == 38 and param_list[1] == 2) {
        style.fg = .{ .rgb = .{ param_list[2], param_list[3], param_list[4] } };
    } else if (param_count >= 5 and param_list[0] == 48 and param_list[1] == 2) {
        style.bg = .{ .rgb = .{ param_list[2], param_list[3], param_list[4] } };
    } else if (param_count >= 1 and param_list[0] == 0) {
        style.* = .{};
    }
}
