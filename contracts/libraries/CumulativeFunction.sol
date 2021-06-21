// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

library CumulativeFunction {
    struct Node {
        uint24 left;
        uint24 right;
        uint208 value;
    }

    function getHeight(uint24 x) internal pure returns (uint256 h) {
        h = 0;
        while (true) {
            if ((x & 1) == 1) {
                break;
            }

            h = h + 1;
            x = x >> 1;
        }
    }

    function findCommon(uint24 x, uint24 y) internal pure returns (uint24) {
        if (x == y) {
            return x;
        }

        uint256 hx = getHeight(x);
        uint256 hy = getHeight(y);
        uint256 i = hx > hy ? hx : hy;
        while (true) {
            uint24 b = uint24(1 << i);
            uint24 px = (x & ~(b - 1)) | b;
            uint24 py = (y & ~(b - 1)) | b;

            if (px == py) {
                return px;
            }

            i = i + 1;
        }
        return 0;
    }

    // @notice Given an existing node (child, may have child/children) and a new node to insert (x, no child),
    //         return their nearest common ancestor (y) after inserting x and child
    // @dev The result of the insertion could be
    //      1,    x = y             x = y
    //           /          or        \
    //          child                 child
    //      2,     y                y
    //           /   \      or    /   \
    //          x    child      child  x
    function insertFully(
        mapping(uint24 => Node) storage self,
        uint24 child,
        uint24 x,
        uint208 v
    ) internal returns (uint24 y) {
        y = findCommon(x, child);

        if (child < y) {
            self[y].left = child;

            uint208 sv = 0;
            uint24 n = child;
            while (n != 0) {
                sv += self[n].value;
                n = self[n].right;
            }

            self[y].value = sv;
        } else if (child > y) {
            self[y].right = child;
        } else {
            // child == y
            // should not happen
            assert(false);
        }

        if (x < y) {
            self[y].left = x;
            self[y].value += v;
        } else if (x > y) {
            self[y].right = x;
        } else {
            // x == y
        }
    }

    // @notice Add v to f(x) so that f(x) <- f(x) + v.
    // @dev The method will traverse from root to x in the cumulative function tree.
    //      It will skip the uninitialized node, and if the node of x does not exist,
    //      it will insert x and insert an extra node if necessary given
    //      p - the most-recent-visited initialized node
    //      child - the existing child of p (can be none)
    //      After the insertion, the tree will like like
    //      1,     p                p      (if child is none)
    //           /          or        \
    //          x                      x
    //
    //      2,     p              p             p           p       from    p (child == p.left)
    //           /               /             /           /              /   \
    //          y          or   y       or    y = x   or  y = x         child ???
    //         / \            /   \          /             \
    //        x  child     child   x       child           child
    //
    //      3,  p                p             p           p        from    p (child == p.right)
    //           \                \             \           \             /   \
    //            y          or   y       or    y = x   or  y = x        ???  child
    //           / \            /   \          /             \
    //          x  child     child   x       child           child
    function add(
        mapping(uint24 => Node) storage self,
        uint256 nbits,
        uint24 x,
        uint208 v
    ) internal {
        require(x != 0, 'x cannot be zero');

        uint24 cx = 0;
        uint24 child = uint24(1 << (nbits - 1));
        uint24 p = 0;

        for (uint256 i = nbits - 1; i >= 0; i--) {
            cx = cx + uint24(1 << i);

            if (x == cx) {
                // Find the Node
                if (x != child) {
                    // Need to create a new node as common ancestor of x and child
                    uint24 newn = x;
                    if (child != 0) {
                        // child should be p.left (x < p) or p.right (x > p)
                        newn = insertFully(self, child, x, v);
                        // assert (x < p and child < p and newn < p) or (x > p and child > p and newn > p)
                        // assert getHeight(newn) < getHeight(p)
                    }

                    if (x < p) {
                        self[p].left = newn;
                    } else {
                        self[p].right = newn;
                    }
                }
                self[x].value += v;
                break;
            }

            if (cx == child) {
                // Find an initialized node
                p = cx; // new parent
                if (x < cx) {
                    self[cx].value += v;
                    child = self[cx].left;
                } else {
                    child = self[cx].right;
                }
            }

            if (x < cx) {
                cx ^= uint24(1 << i);
            }

            if (i == 0) {
                break;
            }
        }
    }

    function remove(
        mapping(uint24 => Node) storage self,
        uint256 nbits,
        uint24 x,
        uint208 v
    ) internal {
        require(x != 0, 'x cannot be zero');

        uint24 cx = uint24(1 << (nbits - 1));

        while (cx != 0) {
            if (x <= cx) {
                self[cx].value -= v;

                if (x == cx) {
                    break;
                }

                cx = self[cx].left;
            } else {
                cx = self[cx].right;
            }
        }
    }

    function get(
        mapping(uint24 => Node) storage self,
        uint256 nbits,
        uint24 x
    ) internal view returns (uint208) {
        uint24 cx = uint24(1 << (nbits - 1));
        uint208 v = 0;

        while (cx != 0) {
            if (x >= cx) {
                v += self[cx].value;

                if (x == cx) {
                    break;
                }

                cx = self[cx].right;
            } else {
                cx = self[cx].left;
            }
        }

        return v;
    }
}

contract CumulativeFunctionTest {
    mapping(uint24 => CumulativeFunction.Node) public cf;
    uint256 public nbits;

    using CumulativeFunction for mapping(uint24 => CumulativeFunction.Node);

    constructor(uint256 _nbits) {
        nbits = _nbits;
    }

    function findCommon(uint24 x, uint24 y) public pure returns (uint24) {
        return CumulativeFunction.findCommon(x, y);
    }

    function add(uint24 x, uint208 v) external {
        cf.add(nbits, x, v);
    }

    function get(uint24 x) external view returns (uint208) {
        return cf.get(nbits, x);
    }

    function remove(uint24 x, uint208 v) external {
        cf.remove(nbits, x, v);
    }
}
