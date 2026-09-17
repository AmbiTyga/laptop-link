# SwiftProtobuf runtime

Unmodified runtime Swift sources from [apple/swift-protobuf](https://github.com/apple/swift-protobuf), release **1.38.1**, commit `55d7a1cc5666b85c13464aea1c4b4a90feccb4c8`.

The runtime is included for builds without SwiftPM or network access. `LICENSE.txt` contains the upstream Apache 2.0 license and Runtime Library Exception; the upstream privacy manifest is retained. Applications include those files in their resources.

The checked-in `ble_wire.pb.swift` was generated with the matching 1.38.1 `protoc-gen-swift` and protoc 25.3. Normal builds do not run a generator. To regenerate after schema changes, run `scripts/generate-protobuf.sh` with the matching generator on PATH. Do not hand-edit generated code or vendored runtime sources.
