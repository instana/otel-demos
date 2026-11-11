package com.instana.test;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.context.annotation.Bean;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.client.RestTemplate;

import javax.servlet.http.HttpServletRequest;
import java.net.URI;

@SpringBootApplication
@SuppressWarnings("unused")
public class Application {

	private static final Logger logger = LoggerFactory.getLogger(Application.class);

	public static void main(String[] args) {
		SpringApplication.run(Application.class, args);
	}

	@Bean
	public RestTemplate restTemplate() {
		return new RestTemplate();
	}

	@RestController
	@RequestMapping(value="**")
	public static class Api {

		@Autowired
		private RestTemplate restTemplate;

		@Value("${target_url:http://server-app:8080/}")
		private String targetUrl;

		@GetMapping
		public String forwardRequest(HttpServletRequest request) {
			logger.info("Middle-app received request path: {}", request.getRequestURI());
			try {
				URI uri = new URI(targetUrl);
				logger.info("Forwarding request to: {}", uri);
				String response = restTemplate.getForObject(uri, String.class);
				logger.info("Received response from server-app: {}", response);
				return response;
			} catch (Exception e) {
				logger.error("Error forwarding request to server-app", e);
				return "Middle-app error: " + e.getMessage();
			}
		}

	}

}
