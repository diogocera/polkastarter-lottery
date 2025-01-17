require 'spec_helper'
require 'csv'
require_relative '../../../lib/services/lottery_service'

RSpec.describe LotteryService do
  let(:service) { described_class.new(balances: balances,
                                      recent_winners: recent_winners,
                                      past_winners: past_winners,
                                      blacklist: blacklist,
                                      max_winners: LotteryService::DEFAULT_MAX_WINNERS,
                                      nft_rare_holders: nft_rare_holders,
                                      nft_common_holders: nft_common_holders) }

  # NOTE: In this "small scenario" we exclude all the top holders and ignore the "privileged never winning" ratio,
  #       just to ease the probability calculations between all the "normal participants".
  #       The full scenario is tested on another file.
  context 'given a specific context' do
    before do
      stub_const 'LotteryService::DEFAULT_MAX_WINNERS', 500
      stub_const 'LotteryService::DEFAULT_TOP_N_HOLDERS', 0 # Ignore these on this context, as we have a really small set and we just want to test shuffle and weights
      stub_const 'LotteryService::DEFAULT_PRIVILEGED_NEVER_WINNING_RATIO', 0 # Ignore these on this context, as we have a really small set and we just want to test shuffle and weights
      stub_const 'Participant::TICKET_PRICE', 250
      stub_const 'Participant::NO_COOLDOWN_MINIMUM_BALANCE', 30_000
      stub_const 'Participant::BALANCE_WEIGHTS', {
        0      => 0.00,
        250    => 1.00,
        1_000  => 1.10,
        3_000  => 1.15,
        10_000 => 1.20,
        30_000 => 1.25
      }

    end

    let(:past_winners)   { ['0x555'] }
    let(:recent_winners) { ['0x666', '0x777', '0x020'] }
    let(:blacklist)      { ['0x888'] }
    let(:nft_rare_holders) { ['0x010'] }
    let(:nft_common_holders) { ['0x020'] }
    let(:balances) {
      {
        '0x111' => 249,           # not enough balance
        '0x222' => 250,           # eligible. never participated
        '0x333' => 1_000,         # eligible. never participated
        '0x444' => 3_000,         # eligible. never participated
        '0x555' => 3_000,         # eligible. previous winner, but not recent winner (i.e. not in cooldown period)
                                  # So, it would not be used in the calculation of the privileged participants
                                  # However, in these simple scenario of tests we're ignoring it
                                  # because we have PRIVILEGED_NEVER_WINNING_RATIO set to 0
        '0x666' => 3_000,         # excluded. recent winner (i.e. in a cooldown period)
        '0x777' => 30_000,        # eligible. recent winner (i.e. in a cooldown period), but skips cool down
                                  # no cooldown (i.e. would be excluded, but is eligible because has >= 30 000 POLS
        '0x888' => 1_000_000_000, # always excluded. e.g: a Polkastarter team address, an exchange, etc,
        '0x010' => 0,             # eligible. has 0 POLS, but has a rare NFT
        '0x020' => 3_000          # eligible. recent winner (i.e. in a cooldown period). However, it holds an NFT, so it bypasses the cool down period
      }
    }

    describe '#tickets' do
      it 'calculates the right number of tickets for each participant' do
        service.run

        tickets = service.participants.map do |participant|
          "#{participant.address} -> #{participant.tickets.round(4)}"
        end

        expect(service.participants.sum(&:tickets)).to eq(196.8)
        expect(tickets).to match_array([
          '0x222 -> 1.0',
          '0x333 -> 4.4',
          '0x444 -> 13.8',
          '0x555 -> 13.8',
          '0x777 -> 150.0',
          # 0x010 do not appear because is a nft tier 1 holder, so always wins
          '0x020 -> 13.8'
        ])
      end
    end

    describe '#eligibles' do
      it 'returns the list of all eligible participants' do
        service.run

        expect(service.eligibles.map(&:address)).to match_array(%w(
          0x222 0x333 0x444 0x555 0x777 0x010 0x020
        ))
      end
    end

    describe '#weights' do
      it 'calculates the right weights' do
        service.run

        weights = service.participants.map do |participant|
          "#{participant.address} -> #{participant.weight}"
        end

        expect(weights).to match_array([
          '0x222 -> 1.0',
          '0x333 -> 1.1',
          '0x444 -> 1.15',
          '0x555 -> 1.15',
          '0x777 -> 1.25',
          # 0x010 do not appear because is a nft tier 1 holder, so always wins
          '0x020 -> 1.15'
        ])
      end
    end

    describe '#winners' do
      it 'returns the winners only ' do
        service.run

        expect(service.winners.map(&:address)).to match_array([
          '0x222',
          '0x333',
          '0x444',
          '0x555',
          '0x777',
          '0x010',
          '0x020'
        ])
      end

      it 'correctly shuffles participants based on theirs weights' do
        # Note that we're only getting the first winner on each exoerimenta,
        # because we just want to calculate probabilities for each of them
        stub_const 'LotteryService::MAX_WINNERS', 1

        top_winners = []
        number_of_experiments = 50_000

        # Run experiments
        puts ""
        experiments = []
        number_of_experiments.times do |index|
          service = described_class.new(balances: balances,
                                        recent_winners: recent_winners,
                                        past_winners: past_winners,
                                        blacklist: blacklist,
                                        max_winners: 1)
          service.run
          experiments << service.winners.map(&:address)

          puts " performed experiment number #{index} of #{number_of_experiments} for a simple scenario" if index % (10_000) == 0
        end

        # Calulcate probabilities
        occurences = experiments.flatten.count_by { |address| address }
        probabilities = occurences.transform_values { |value| value.to_f / number_of_experiments }

        # Calculate if all addresses match the expected probability
        error_margin = 0.01
        expected_probabilities = {
          "0x222" => 0.0055, #  0.6% expected
          "0x333" => 0.0240, #  2.4% expected
          "0x444" => 0.0754, #  7.5% expected
          "0x555" => 0.0754, #  7.5% expected
          "0x777" => 0.8197  # 81.9% expected
        }
        all_true = probabilities.all? do |address, probability|
          probability >= expected_probabilities[address] - error_margin &&
          probability <= expected_probabilities[address] + error_margin
        end

        # Veredict
        expect(probabilities.values.sum).to eq(1)
        expect(all_true).to be_truthy
      end
    end
  end
end
