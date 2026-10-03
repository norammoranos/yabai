static struct window minimum_test_windows[4];

static void minimum_test_setup(void)
{
    memset(minimum_test_windows, 0, sizeof(minimum_test_windows));
    table_init(&g_window_manager.window, 8, hash_wm, compare_wm);
    g_space_manager.split_ratio = 0.5f;
    g_space_manager.split_type = SPLIT_AUTO;
    for (int i = 0; i < 4; ++i) {
        minimum_test_windows[i].id = i + 1;
        table_add(&g_window_manager.window, &minimum_test_windows[i].id, &minimum_test_windows[i]);
    }
}

static struct window_node minimum_test_leaf(int id, float width, float height)
{
    minimum_test_windows[id-1].minimum_size = CGSizeMake(width, height);
    return (struct window_node) { .window_list = {id}, .window_count = 1 };
}

TEST_FUNC(minimum_ratio_avoids_overlap, {
    minimum_test_setup();
    struct window_node a = minimum_test_leaf(1, 833, 400);
    struct window_node b = minimum_test_leaf(2, 600, 400);
    struct window_node root = { .area = {0, 42, 1512, 940}, .left = &a, .right = &b, .split = SPLIT_Y, .ratio = .5f };
    a.parent = b.parent = &root;
    struct view view = { .root = &root, .layout = VIEW_BSP, .window_gap = 8, .flags = VIEW_ENABLE_GAP };
    window_node_update(&view, &root);
    TEST_CHECK(a.area.w >= 833, true);
    TEST_CHECK(b.area.w >= 600, true);
    TEST_CHECK(a.area.x + a.area.w + 8 <= b.area.x, true);
    table_free(&g_window_manager.window);
})

TEST_FUNC(minimum_changes_split_before_stacking, {
    minimum_test_setup();
    struct window_node a = minimum_test_leaf(1, 900, 400);
    struct window_node b = minimum_test_leaf(2, 800, 400);
    struct window_node root = { .area = {0, 42, 1512, 940}, .left = &a, .right = &b, .split = SPLIT_Y, .ratio = .5f };
    a.parent = b.parent = &root;
    struct view view = { .root = &root, .layout = VIEW_BSP, .window_gap = 8, .flags = VIEW_ENABLE_GAP };
    window_node_update(&view, &root);
    TEST_CHECK(root.split, SPLIT_X);
    TEST_CHECK(root.overflow_stack, false);
    TEST_CHECK(a.area.h >= 400 && b.area.h >= 400, true);
    table_free(&g_window_manager.window);
})

TEST_FUNC(minimum_stack_unfold_preserves_tree, {
    minimum_test_setup();
    struct window_node a = minimum_test_leaf(1, 900, 600);
    struct window_node b = minimum_test_leaf(2, 800, 600);
    struct window_node root = { .area = {0, 42, 1512, 940}, .left = &a, .right = &b, .split = SPLIT_Y, .ratio = .5f };
    a.parent = b.parent = &root;
    struct view view = { .root = &root, .layout = VIEW_BSP, .window_gap = 8, .flags = VIEW_ENABLE_GAP };
    window_node_update(&view, &root);
    TEST_CHECK(root.overflow_stack, true);
    TEST_CHECK(a.area.w == root.area.w && b.area.w == root.area.w, true);
    root.area.w = 2000;
    window_node_update(&view, &root);
    TEST_CHECK(root.overflow_stack, false);
    TEST_CHECK(root.left == &a && root.right == &b, true);
    TEST_CHECK(a.area.w + b.area.w + 8 == root.area.w, true);
    table_free(&g_window_manager.window);
})

TEST_FUNC(minimum_nested_layout_is_stable, {
    minimum_test_setup();
    uint32_t seed = 42;
    for (int iteration = 0; iteration < 600; ++iteration) {
        struct window_node leaves[4];
        for (int i = 0; i < 4; ++i) {
            seed = seed * 1664525u + 1013904223u;
            float width = 180 + seed % 821;
            seed = seed * 1664525u + 1013904223u;
            leaves[i] = minimum_test_leaf(i+1, width, 120 + seed % 501);
        }
        struct window_node left = { .left = &leaves[0], .right = &leaves[1], .split = SPLIT_X, .ratio = .5f };
        struct window_node right = { .left = &leaves[2], .right = &leaves[3], .split = SPLIT_X, .ratio = .5f };
        struct window_node root = { .area = {0, 42, 1512, 940}, .left = &left, .right = &right, .split = SPLIT_Y, .ratio = .5f };
        leaves[0].parent = leaves[1].parent = &left;
        leaves[2].parent = leaves[3].parent = &right;
        left.parent = right.parent = &root;
        struct view view = { .root = &root, .layout = VIEW_BSP, .window_gap = 8, .flags = VIEW_ENABLE_GAP };
        window_node_update(&view, &root);
        struct area before[4];
        for (int i = 0; i < 4; ++i) {
            before[i] = leaves[i].area;
            TEST_CHECK(minimum_fits(minimum_test_windows[i].minimum_size, leaves[i].area), true);
            for (int j = i+1; j < 4; ++j) {
                struct window_node *group = window_node_overflow_group(&leaves[i]);
                if (group && group == window_node_overflow_group(&leaves[j])) continue;
                float overlap_w = fminf(leaves[i].area.x + leaves[i].area.w, leaves[j].area.x + leaves[j].area.w)
                                - fmaxf(leaves[i].area.x, leaves[j].area.x);
                float overlap_h = fminf(leaves[i].area.y + leaves[i].area.h, leaves[j].area.y + leaves[j].area.h)
                                - fmaxf(leaves[i].area.y, leaves[j].area.y);
                TEST_CHECK(overlap_w > 1 && overlap_h > 1, false);
            }
        }
        window_node_update(&view, &root);
        for (int i = 0; i < 4; ++i) TEST_CHECK(memcmp(&before[i], &leaves[i].area, sizeof(struct area)) == 0, true);
        if (!result) { printf("iteration=%d\n", iteration); break; }
    }
    table_free(&g_window_manager.window);
})

TEST_FUNC(minimum_manual_stack_survives_unfold, {
    minimum_test_setup();
    struct window_node a = minimum_test_leaf(1, 900, 600);
    a.window_list[1] = 3;
    a.window_count = 2;
    minimum_test_windows[2].minimum_size = CGSizeMake(950, 650);
    struct window_node b = minimum_test_leaf(2, 800, 600);
    struct window_node root = { .area = {0, 42, 1512, 940}, .left = &a, .right = &b, .split = SPLIT_Y, .ratio = .5f };
    a.parent = b.parent = &root;
    struct view view = { .root = &root, .layout = VIEW_BSP, .window_gap = 8, .flags = VIEW_ENABLE_GAP };
    window_node_update(&view, &root);
    TEST_CHECK(root.overflow_stack, true);
    root.area.w = 2400;
    window_node_update(&view, &root);
    TEST_CHECK(root.overflow_stack, false);
    TEST_CHECK(a.window_count, 2);
    TEST_CHECK(a.window_list[1], 3);
    TEST_CHECK(a.area.w >= 950, true);
    table_free(&g_window_manager.window);
})
