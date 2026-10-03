/* Minimum-size projection keeps the editable BSP tree intact. Automatic
 * overflow stacks are a projection; manual stacks remain ordinary leaves. */
struct minimum_choice {
    CGSize size;
    enum window_node_split split;
    struct minimum_choice *left, *right;
};

struct minimum_choices {
    struct window_node *node;
    struct minimum_choice *items;
    struct minimum_choices *left, *right;
};

static CGSize minimum_leaf_size(struct window_node *node)
{
    CGSize size = CGSizeMake(1, 1);
    for (int i = 0; i < node->window_count; ++i) {
        struct window *window = window_manager_find_window(&g_window_manager, node->window_list[i]);
        if (!window) continue;
        size.width = fmax(size.width, window->minimum_size.width);
        size.height = fmax(size.height, window->minimum_size.height);
    }
    return size;
}

static CGSize minimum_combine(CGSize a, CGSize b, enum window_node_split split, int gap)
{
    return split == SPLIT_Y
        ? CGSizeMake(a.width + b.width + gap, fmax(a.height, b.height))
        : CGSizeMake(fmax(a.width, b.width), a.height + b.height + gap);
}

static bool minimum_fits(CGSize size, struct area area)
{
    return size.width <= area.w && size.height <= area.h;
}

static struct minimum_choices *minimum_choices_build(struct view *view, struct window_node *node)
{
    struct minimum_choices *choices = calloc(1, sizeof(*choices));
    choices->node = node;
    node->view = view;
    if (window_node_is_leaf(node)) {
        buf_push(choices->items, ((struct minimum_choice) { .size = minimum_leaf_size(node) }));
        return choices;
    }
    choices->left = minimum_choices_build(view, node->left);
    choices->right = minimum_choices_build(view, node->right);
    if (!node->minimum_projected_split || node->split != node->minimum_projected_split) {
        node->minimum_preferred_split = window_node_get_split(view, node);
    }
    enum window_node_split preferred = node->minimum_preferred_split;
    for (int axis = 0; axis < 2; ++axis) {
        enum window_node_split split = axis ? (preferred == SPLIT_Y ? SPLIT_X : SPLIT_Y) : preferred;
        for (int l = 0; l < buf_len(choices->left->items); ++l) {
            for (int r = 0; r < buf_len(choices->right->items); ++r) {
                struct minimum_choice candidate = {
                    .left = &choices->left->items[l], .right = &choices->right->items[r], .split = split
                };
                candidate.size = minimum_combine(candidate.left->size, candidate.right->size, split, window_node_get_gap(view));
                bool dominated = false;
                for (int i = 0; i < buf_len(choices->items); ++i) {
                    CGSize size = choices->items[i].size;
                    if (size.width <= candidate.size.width && size.height <= candidate.size.height) {
                        dominated = true;
                        break;
                    }
                }
                if (dominated) continue;
                /* Entry zero preserves the user's existing directions when they
                 * fit. Remaining entries form a Pareto frontier of alternatives. */
                for (int i = buf_len(choices->items) - 1; i > 0; --i) {
                    CGSize size = choices->items[i].size;
                    if (candidate.size.width <= size.width && candidate.size.height <= size.height) {
                        buf_del(choices->items, i);
                    }
                }
                buf_push(choices->items, candidate);
            }
        }
    }
    return choices;
}

static void minimum_choices_free(struct minimum_choices *choices)
{
    if (choices->left) minimum_choices_free(choices->left);
    if (choices->right) minimum_choices_free(choices->right);
    buf_free(choices->items);
    free(choices);
}

static void minimum_split_areas(struct view *view, struct window_node *node,
                                enum window_node_split split, CGSize a, CGSize b)
{
    int gap = window_node_get_gap(view);
    float extent = (split == SPLIT_Y ? node->area.w : node->area.h) - gap;
    float amin = split == SPLIT_Y ? a.width : a.height;
    float bmin = split == SPLIT_Y ? b.width : b.height;
    float first = floorf(extent * window_node_get_ratio(node) + 0.0001f);
    first = fmaxf(ceilf(amin), fminf(first, floorf(extent - bmin)));
    node->left->area = node->right->area = node->area;
    if (split == SPLIT_Y) {
        node->left->area.w = first;
        node->right->area.w = extent - first;
        node->right->area.x += first + gap;
    } else {
        node->left->area.h = first;
        node->right->area.h = extent - first;
        node->right->area.y += first + gap;
    }
    node->split = split;
    node->minimum_projected_split = split;
}

static void minimum_apply(struct view *view, struct window_node *node, struct minimum_choice *choice)
{
    node->overflow_stack = false;
    node->minimum_projected_split = node->split;
    if (window_node_is_leaf(node)) return;
    minimum_split_areas(view, node, choice->split, choice->left->size, choice->right->size);
    minimum_apply(view, node->left, choice->left);
    minimum_apply(view, node->right, choice->right);
}

static CGSize minimum_assign_stack_area(struct window_node *node, struct area area)
{
    node->area = area;
    node->overflow_stack = false;
    if (window_node_is_leaf(node)) return minimum_leaf_size(node);
    CGSize a = minimum_assign_stack_area(node->left, area);
    CGSize b = minimum_assign_stack_area(node->right, area);
    return CGSizeMake(fmax(a.width, b.width), fmax(a.height, b.height));
}

static CGSize minimum_project(struct view *view, struct minimum_choices *choices)
{
    struct window_node *node = choices->node;
    for (int i = 0; i < buf_len(choices->items); ++i) {
        if (minimum_fits(choices->items[i].size, node->area)) {
            minimum_apply(view, node, &choices->items[i]);
            return choices->items[i].size;
        }
    }
    if (window_node_is_leaf(node)) return choices->items[0].size;
    /* Try grouping a smaller subtree first, so other tiles remain independent. */
    enum window_node_split preferred = node->minimum_preferred_split;
    area_make_pair(preferred, window_node_get_gap(view), window_node_get_ratio(node),
                   &node->area, &node->left->area, &node->right->area);
    node->split = node->minimum_projected_split = preferred;
    CGSize a = minimum_project(view, choices->left);
    CGSize b = minimum_project(view, choices->right);
    for (int axis = 0; axis < 2; ++axis) {
        enum window_node_split split = axis ? (preferred == SPLIT_Y ? SPLIT_X : SPLIT_Y) : preferred;
        CGSize size = minimum_combine(a, b, split, window_node_get_gap(view));
        if (minimum_fits(size, node->area)) {
            node->overflow_stack = false;
            minimum_split_areas(view, node, split, a, b);
            /* Preserve the child grouping decision while shifting its area. */
            if (node->left->overflow_stack) {
                minimum_assign_stack_area(node->left, node->left->area);
                node->left->overflow_stack = true;
            } else minimum_project(view, choices->left);
            if (node->right->overflow_stack) {
                minimum_assign_stack_area(node->right, node->right->area);
                node->right->overflow_stack = true;
            } else minimum_project(view, choices->right);
            return size;
        }
    }
    CGSize size = minimum_assign_stack_area(node, node->area);
    node->overflow_stack = true;
    return size;
}

struct window_node *window_node_overflow_group(struct window_node *node)
{
    struct window_node *group = NULL;
    for (; node; node = node->parent) if (node->overflow_stack) group = node;
    return group;
}

static void window_node_collect_stack(struct window_node *node, uint32_t **ids)
{
    if (window_node_is_leaf(node)) {
        for (int i = 0; i < node->window_count; ++i) ts_buf_push(*ids, node->window_list[i]);
    } else {
        window_node_collect_stack(node->left, ids);
        window_node_collect_stack(node->right, ids);
    }
}

int window_node_projected_stack(struct window_node *node, uint32_t **ids)
{
    struct window_node *group = window_node_overflow_group(node);
    window_node_collect_stack(group ? group : node, ids);
    return ts_buf_len(*ids);
}
