package otel;

import java.util.ArrayList;
import java.util.List;

public class Sample {

    private int numberValue;

    public Sample() {
        this.numberValue = 1;
    }

    public List<Integer> playSample(int numTimes) {
        List<Integer> results = new ArrayList<Integer>();
        for (int i = 0; i < numTimes; i++) {
            results.add(addOne());
        }
        return results;
    }

    private int addOne() {
        return this.numberValue++;
    }
}