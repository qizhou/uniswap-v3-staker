import { ethers } from 'hardhat'
import { CumulativeFunctionTest } from '../typechain/CumulativeFunctionTest'
import { expect } from './shared'

describe('CumulativeFunction', () => {
  let cfTest: CumulativeFunctionTest

  beforeEach('deploy TickTest', async () => {
    const cfTestFactory = await ethers.getContractFactory('CumulativeFunctionTest')
    cfTest = (await cfTestFactory.deploy(14)) as CumulativeFunctionTest
  })

  describe('#add', () => {
    it('add single', async () => {
      await cfTest.add(5342, 10)
      expect(await cfTest.get(153)).to.eq('0')
      expect(await cfTest.get(5341)).to.eq('0')
      expect(await cfTest.get(5342)).to.eq('10')
      expect(await cfTest.get(15342)).to.eq('10')
    })

    it('add two', async () => {
      await cfTest.add(1234, 10)
      await cfTest.add(5678, 10)
      expect(await cfTest.get(153)).to.eq('0')
      expect(await cfTest.get(1233)).to.eq('0')
      expect(await cfTest.get(1234)).to.eq('10')
      expect(await cfTest.get(5677)).to.eq('10')
      expect(await cfTest.get(5678)).to.eq('20')
      expect(await cfTest.get(56780)).to.eq('20')
    })

    it('add three', async () => {
      await cfTest.add(1234, 10)
      await cfTest.add(5678, 10)
      await cfTest.add(8678, 10)
      expect(await cfTest.get(153)).to.eq('0')
      expect(await cfTest.get(1233)).to.eq('0')
      expect(await cfTest.get(1234)).to.eq('10')
      expect(await cfTest.get(5677)).to.eq('10')
      expect(await cfTest.get(5678)).to.eq('20')
      expect(await cfTest.get(56780)).to.eq('30')
    })
  })

  describe('#add/remove', () => {
    it('add/remove single', async () => {
      await cfTest.add(5342, 10);
      await cfTest.remove(5342, 10);
      expect(await cfTest.get(153)).to.eq('0');
      expect(await cfTest.get(5341)).to.eq('0');
      expect(await cfTest.get(5342)).to.eq('0');
      expect(await cfTest.get(15342)).to.eq('0');
    })

    it('add/remove two', async () => {
      await cfTest.add(1234, 10);
      await cfTest.add(5678, 10);
      await cfTest.remove(1234, 10);
      expect(await cfTest.get(153)).to.eq('0');
      expect(await cfTest.get(1233)).to.eq('0');
      expect(await cfTest.get(1234)).to.eq('0');
      expect(await cfTest.get(5677)).to.eq('0');
      expect(await cfTest.get(5678)).to.eq('10');
      expect(await cfTest.get(56780)).to.eq('10');
      await cfTest.remove(5678, 10);
      expect(await cfTest.get(153)).to.eq('0');
      expect(await cfTest.get(1233)).to.eq('0');
      expect(await cfTest.get(1234)).to.eq('0');
      expect(await cfTest.get(5677)).to.eq('0');
      expect(await cfTest.get(5678)).to.eq('0');
      expect(await cfTest.get(56780)).to.eq('0');
    })

    it('add/remove three', async () => {
      await cfTest.add(1234, 10);
      await cfTest.add(5678, 10);
      await cfTest.add(8678, 10);
      await cfTest.remove(8678, 10);
      expect(await cfTest.get(153)).to.eq('0');
      expect(await cfTest.get(1233)).to.eq('0');
      expect(await cfTest.get(1234)).to.eq('10');
      expect(await cfTest.get(5677)).to.eq('10');
      expect(await cfTest.get(5678)).to.eq('20');
      expect(await cfTest.get(56780)).to.eq('20');
      await cfTest.remove(5678, 10);
      expect(await cfTest.get(153)).to.eq('0');
      expect(await cfTest.get(1233)).to.eq('0');
      expect(await cfTest.get(1234)).to.eq('10');
      expect(await cfTest.get(5677)).to.eq('10');
      expect(await cfTest.get(5678)).to.eq('10');
      expect(await cfTest.get(56780)).to.eq('10');
      await cfTest.remove(1234, 10);
      expect(await cfTest.get(153)).to.eq('0');
      expect(await cfTest.get(1233)).to.eq('0');
      expect(await cfTest.get(1234)).to.eq('0');
      expect(await cfTest.get(5677)).to.eq('0');
      expect(await cfTest.get(5678)).to.eq('0');
      expect(await cfTest.get(56780)).to.eq('0');
    })
  })
})
