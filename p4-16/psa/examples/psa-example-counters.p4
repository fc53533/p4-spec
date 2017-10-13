/*
Copyright 2017 Cisco Systems, Inc.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

#include <core.p4>
#include "../psa.p4"


typedef bit<48>  EthernetAddress;

header ethernet_t {
    EthernetAddress dstAddr;
    EthernetAddress srcAddr;
    bit<16>         etherType;
}

header ipv4_t {
    bit<4>  version;
    bit<4>  ihl;
    bit<8>  diffserv;
    bit<16> totalLen;
    bit<16> identification;
    bit<3>  flags;
    bit<13> fragOffset;
    bit<8>  ttl;
    bit<8>  protocol;
    bit<16> hdrChecksum;
    bit<32> srcAddr;
    bit<32> dstAddr;
}

struct fwd_metadata_t {
}

struct metadata {
    fwd_metadata_t fwd_metadata;
}

// BEGIN:Counter_Example_Part1
typedef bit<48> ByteCounter_t;
typedef bit<32> PacketCounter_t;
typedef bit<80> PacketByteCounter_t;

const PortId_t NUM_PORTS = 512;

struct headers {
    ethernet_t       ethernet;
    ipv4_t           ipv4;
}
// END:Counter_Example_Part1

parser CommonParser(packet_in buffer,
                    out headers parsed_hdr,
                    inout metadata user_meta)
{
    state start {
        transition parse_ethernet;
    }
    state parse_ethernet {
        buffer.extract(parsed_hdr.ethernet);
        transition select(parsed_hdr.ethernet.etherType) {
            0x0800: parse_ipv4;
            default: accept;
        }
    }
    state parse_ipv4 {
        buffer.extract(parsed_hdr.ipv4);
        transition accept;
    }
}

parser IngressParserImpl(packet_in buffer,
                         out headers parsed_hdr,
                         inout metadata user_meta,
                         in psa_ingress_parser_input_metadata_t istd,
                         out psa_parser_output_metadata_t ostd)
{
    CommonParser() p;

    state start {
        p.apply(buffer, parsed_hdr, user_meta);
        transition accept;
    }
}

parser EgressParserImpl(packet_in buffer,
                        out headers parsed_hdr,
                        inout metadata user_meta,
                        in psa_egress_parser_input_metadata_t istd,
                        out psa_parser_output_metadata_t ostd)
{
    CommonParser() p;

    state start {
        p.apply(buffer, parsed_hdr, user_meta);
        transition accept;
    }
}

// BEGIN:Counter_Example_Part2
control ingress(inout headers hdr,
                inout metadata user_meta,
                PacketReplicationEngine pre,
                in    psa_ingress_input_metadata_t  istd,
                inout psa_ingress_output_metadata_t ostd)
{
    Counter<ByteCounter_t, PortId_t>((bit<32>) NUM_PORTS, CounterType_t.BYTES)
        port_bytes_in;
    DirectCounter<PacketByteCounter_t>(CounterType_t.PACKETS_AND_BYTES)
        per_prefix_pkt_byte_count;

    action next_hop(PortId_t oport) {
        per_prefix_pkt_byte_count.count();
        send_to_port(ostd, oport);
    }
    action default_route_drop() {
        per_prefix_pkt_byte_count.count();
        ingress_drop(ostd);
    }
    table ipv4_da_lpm {
        key = { hdr.ipv4.dstAddr: lpm; }
        actions = {
            next_hop;
            default_route_drop;
        }
        default_action = default_route_drop;
        psa_direct_counters = {
            // table ipv4_da_lpm owns this DirectCounter instance
            per_prefix_pkt_byte_count
        };
    }
    apply {
        port_bytes_in.count(istd.ingress_port);
        if (hdr.ipv4.isValid()) {
            ipv4_da_lpm.apply();
        }
    }
}

control egress(inout headers hdr,
               inout metadata user_meta,
               BufferingQueueingEngine bqe,
               in    psa_egress_input_metadata_t  istd,
               inout psa_egress_output_metadata_t ostd)
{
    Counter<ByteCounter_t, PortId_t>((bit<32>) NUM_PORTS, CounterType_t.BYTES)
        port_bytes_out;
    apply {
        // By doing these stats updates on egress, then because
        // multicast replication happens before egress processing,
        // this update will occur once for each copy made, which in
        // this example is intentional.
        port_bytes_out.count(istd.egress_port);
    }
}
// END:Counter_Example_Part2

control DeparserImpl(packet_out packet, inout headers hdr, in metadata meta) {
    apply {
        packet.emit(hdr.ethernet);
        packet.emit(hdr.ipv4);
    }
}

PSA_Switch(IngressParserImpl(),
           ingress(),
           DeparserImpl(),
           EgressParserImpl(),
           egress(),
           DeparserImpl()) main;
