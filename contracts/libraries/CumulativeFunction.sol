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

    function insertFully(mapping(uint24 => Node) storage self, uint24 child, uint24 x, uint208 v) internal returns (uint24 y) {
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
        }

        if (x < y) {
            self[y].left = x;
            self[y].value += v;
        } else if (x > y) {
            self[y].right = x;
        }
    }

    function add(mapping(uint24 => Node) storage self, uint256 nbits, uint24 x, uint208 v) internal {
         require(x != 0, "x cannot be zero");

         uint24 cx = 0;
         uint24 child = uint24(1 << (nbits - 1));
         uint24 p = 0;

         for (uint256 i = nbits - 1; i >= 0; i--) {
            cx = cx + uint24(1 << i);

            if (x == cx) {
                // Find the Node
                if (x != child) {
                    // Need to create a new node for x and parent node for x and child
                    uint24 newn = x;
                    if (child != 0) {
                        // child should be p.left (x < p) or p.right (x > p)
                        newn = insertFully(self, child, x, v);
                    }

                    if (x < p) {
                        self[p].left = newn;
                    } else {
                        self[p].right = newn;
                    }
                }
                self[x].value += v;
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

    function get(mapping(uint24 => Node) storage self, uint256 nbits, uint24 x) internal view returns (uint208) {
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

    constructor(uint256 _nbits) { nbits = _nbits; }

    function findCommon(uint24 x, uint24 y) public pure returns (uint24) {
        return CumulativeFunction.findCommon(x, y);
    }

    function add(uint24 x, uint208 v) external {
        cf.add(nbits, x, v);
    }

    function get(uint24 x) external view returns (uint208) {
        return cf.get(nbits, x);
    }
}
