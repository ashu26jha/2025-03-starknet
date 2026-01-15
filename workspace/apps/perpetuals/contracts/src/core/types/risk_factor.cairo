use core::num::traits::zero::Zero;

// Fixed-point decimal with 2 decimal places.
//
// Example: 0.75 is represented as 75.
#[derive(Copy, Debug, Default, Drop, PartialEq, Serde, starknet::Store)]
pub struct RiskFactor {
    value: u8 // Stores number * 100
}

const DENOMINATOR: u8 = 100_u8;

#[generate_trait]
pub impl RiskFactorImpl of RiskFactorTrait {
    fn new(value: u8) -> RiskFactor {
        assert(value <= DENOMINATOR, 'Value must be <= 100');
        RiskFactor { value }
    }

    /// Multiplies the fixed-point value by `other` and divides by DENOMINATOR.
    /// Integer division truncates toward zero to the nearest integer.
    ///
    /// Example: RiskFactorTrait::new(75).mul(300) == 225
    /// Example: RiskFactorTrait::new(75).mul(301) == 225
    /// Example: RiskFactorTrait::new(75).mul(-5) == -3
    fn mul(self: @RiskFactor, other: u128) -> u128 {
        ((*self.value).into() * other) / DENOMINATOR.into()
    }
}

impl RiskFactorZero of core::num::traits::Zero<RiskFactor> {
    fn zero() -> RiskFactor {
        RiskFactor { value: 0 }
    }
    fn is_zero(self: @RiskFactor) -> bool {
        self.value.is_zero()
    }
    fn is_non_zero(self: @RiskFactor) -> bool {
        self.value.is_non_zero()
    }
}
