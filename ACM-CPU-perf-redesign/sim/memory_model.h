#pragma once
#include <cstddef>
#include <cstdint>
#include <deque>
#include <optional>
#include <stdexcept>
#include <vector>

struct BusRequest {
    uint32_t address, data;
    uint8_t strobe;
    bool write;
    bool operator==(const BusRequest &other) const {
        return address == other.address && data == other.data &&
               strobe == other.strobe && write == other.write;
    }
};
struct BusResponse { uint32_t data; bool error; };

// One ordered response channel, independent pipelined request channel. A read
// samples RAM when it first reaches the response channel; all older writes have
// completed by then. Holding the response also holds its sampled data.
class OrderedMemory {
    struct Pending {
        BusRequest request;
        uint64_t due;
        bool error;
        std::optional<BusResponse> presented;
    };
    std::vector<uint8_t> &memory_;
    std::deque<Pending> pending_;
    size_t capacity_;
public:
    OrderedMemory(std::vector<uint8_t> &memory, size_t capacity)
        : memory_(memory), capacity_(capacity) {
        if (!capacity) throw std::runtime_error("memory capacity must be positive");
    }
    size_t size() const { return pending_.size(); }
    size_t capacity() const { return capacity_; }
    bool empty() const { return pending_.empty(); }
    bool can_accept() const { return size() < capacity_; }
    void accept(BusRequest request, uint64_t due, bool error) {
        if (!can_accept()) throw std::runtime_error("memory outstanding capacity exceeded");
        if ((request.address & 3) || request.address > memory_.size() - 4)
            throw std::runtime_error("invalid external RAM request");
        pending_.push_back(Pending{request, due, error, std::nullopt});
    }
    std::optional<BusResponse> response(uint64_t cycle) {
        if (empty() || cycle < pending_.front().due) return std::nullopt;
        auto &head = pending_.front();
        if (!head.presented) {
            uint32_t data = 0;
            for (unsigned j = 0; j < 4; ++j)
                data |= uint32_t(memory_[head.request.address+j]) << (8*j);
            head.presented = BusResponse{data, head.error};
        }
        return head.presented;
    }
    void complete() {
        if (empty() || !pending_.front().presented)
            throw std::runtime_error("memory response completed before presentation");
        const auto &head = pending_.front();
        if (head.request.write && !head.error)
            for (unsigned j = 0; j < 4; ++j)
                if ((head.request.strobe >> j) & 1)
                    memory_[head.request.address+j] = head.request.data >> (8*j);
        pending_.pop_front();
    }
};
